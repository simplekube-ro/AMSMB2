## Context

`SMB2Client` in `AMSMB2/Context.swift` serializes all libsmb2 access on a single serial
`eventLoopQueue` (`DispatchQueue`, `qos: .userInitiated`). Today the wire layer is libsmb2's
built-in TCP socket, driven like this (verified against the current source):

- `connect(server:share:user:)` queues `smb2_connect_share_async` on `eventLoopQueue`, then
  runs `pollUntilComplete(_:)` — a `poll(2)` loop with a 100 ms tick that calls
  `smb2_service(context, revents)` until the connect callback fires. Only after connect does it
  call `startSocketMonitoring()`. (The fd does not exist until connect, so DispatchSource can't
  be created earlier.)
- `startSocketMonitoring()` builds a `SocketMonitor` over `smb2_get_fd(context)` with a
  `DispatchSource.makeReadSource` (always resumed) and a lazily-resumed
  `DispatchSource.makeWriteSource`. `activateWriteSourceIfNeeded` toggles the write source based
  on `smb2_which_events(context) & POLLOUT`.
- `handleSocketEvent()` (event handler, runs on `eventLoopQueue`) re-polls the fd with a 0 ms
  timeout to get `revents`, then calls `smb2_service(context, revents)`; on a negative result it
  destroys the context and calls `failAllPendingOperations`.
- Each operation goes through `async_await` / `async_await_pdu`, which suspend on a
  `CheckedContinuation`. A per-operation `CBData` (retained via `Unmanaged.passRetained`,
  released in `generic_handler` via `takeRetainedValue`) carries the continuation; `isAbandoned`
  guards against double-resume on timeout/connection-drop races. Timeouts are armed with
  `eventLoopQueue.asyncAfter`. Cancellation uses `withTaskCancellationHandler`.

Everything that touches `smb2_context` runs on `eventLoopQueue`. The seam must preserve that
invariant exactly: it changes *how bytes move*, not *where libsmb2 is called*.

The `simplekube-ro/libsmb2` fork exposes (in `include/smb2/libsmb2.h`):

```c
#define SMB2_TRANSPORT_TCP   0   /* libsmb2's BUILT-IN socket */
#define SMB2_TRANSPORT_QUIC  1   /* external transport via ext */
#define SMB2_TRANSPORT_AUTO  2   /* external transport via ext */

struct smb2_external_transport {
    void *userdata;
    int (*connect)(void *userdata, const char *host, int port);
    int (*send)(void *userdata, const uint8_t *buf, size_t len);
    int (*recv)(void *userdata, uint8_t *buf, size_t max_len);
    int (*close)(void *userdata);
};

int smb2_set_transport(struct smb2_context *smb2, int type,
                       const struct smb2_external_transport *ext);
int smb2_get_timeout(struct smb2_context *smb2, struct timeval *tv);
int smb2_service_timeout(struct smb2_context *smb2);
```

Note: the C target in `Package.swift` is named `libsmb2`, but it is imported in Swift as the
module `SMB2` (declared by the modulemap inside the submodule). The submodule is currently
**uninitialized** and points at upstream `sahlberg/libsmb2`, which lacks this API — T1 fixes that.

## Goals / Non-Goals

**Goals**
- A pluggable, NIO-free, libsmb2-free Swift transport seam that is unit-testable in isolation.
- Correct sync-C ↔ async-Swift bridging with no buffer-lifetime use-after-free and clean
  teardown on close/cancel.
- A no-fd servicing loop that drives libsmb2 from inbound-ready signals + timers, preserving the
  existing continuation/cancellation/timeout semantics.
- TCP routed through `NIOTransportServices` on Apple, validated against the real Samba suite with
  no observable behavior change before becoming the default.
- Zero new Swift 6 strict-concurrency warnings.

**Non-Goals**
- QUIC implementation, zero-copy I/O, Linux NIO, and any public `SMB2Manager` API change.

## Key Decisions

### D1 — The naming trap: external transport uses QUIC/AUTO, never TCP

`SMB2_TRANSPORT_TCP` (== 0) selects libsmb2's **built-in** BSD socket and **ignores** the `ext`
struct. To route our external NIO transport through the seam we MUST call
`smb2_set_transport(ctx, SMB2_TRANSPORT_QUIC | SMB2_TRANSPORT_AUTO, &ext)` with `ext` populated,
**before connect**. This is counterintuitive: the constant named "TCP" is exactly the one we do
NOT use for our (TCP-carrying) NIO transport. Every code path and test that wires the seam must
assert this. We default to `SMB2_TRANSPORT_AUTO` for the external selector (it lets libsmb2 pick
external servicing semantics without committing to QUIC-specific behavior), and document why.

### D2 — Seam buffer type: `Data`, not `ByteBuffer`

Issue #23 sketched the protocol with `ByteBuffer`. We instead use **`Data`** at the seam and
convert to/from `ByteBuffer` *inside* `TCPTransportApple`. Rationale:

- **Keeps the seam NIO-free.** `SMBTransport`, `SMBTransportKind`, the bridge, and `MockTransport`
  then have no SwiftNIO dependency and compile/test on any platform (incl. Linux and CI legs
  without NIO resolved). The QUIC transport can reuse the identical seam.
- **Matches the codebase idiom.** `SMB2FileHandle`, `RawBuffer`, and the public API already speak
  `Data`; `POSIXError(.CODE)` is the error convention. `Data` is `Sendable`, contiguous, and
  converts cheaply to `ByteBuffer(data:)` / from `buffer.readData(length:)`.
- **The bridge copies at the C boundary anyway** (D4), producing `Data` naturally; handing
  `ByteBuffer` to the seam would just force an extra conversion on the libsmb2 side.

Trade-off: one `Data`↔`ByteBuffer` copy inside `TCPTransportApple`. Acceptable — copy-at-boundary
is already mandatory (D4), and zero-copy is an explicit non-goal. `[UInt8]` was considered but
`Data` integrates better with Foundation and the existing buffer code; rejected for consistency.

The protocol therefore is:

```swift
public protocol SMBTransport: Sendable {
    func connect(host: String, port: Int) async throws
    func send(_ bytes: Data) async throws
    func receive() async throws -> Data   // empty Data signals graceful EOF
    func close() async
}

public enum SMBTransportKind: Sendable { case tcp, quic, automatic }
```

### D3 — Sendable / actor isolation for Swift 6

The bridge holds mutable inbound/outbound buffers that are touched both from the synchronous C
callbacks (running on `eventLoopQueue`) and from async pump tasks. To stay strict-concurrency
clean we model the bridge's mutable state as an **`actor`** (the `TransportBridge` buffering
state) and keep the C trampolines as free functions that hop onto the bridge via `Unmanaged`.
Because the C callbacks are synchronous and must return a value immediately, the parts the
callbacks touch synchronously (drain-what's-buffered, enqueue-and-return) use a small
**lock-guarded buffer** (an `NSLock`/`os_unfair_lock` wrapper with *synchronous* helper methods)
rather than actor `await` — per the CLAUDE.md gotcha that `NSLock.lock()/unlock()` and unsafe-byte
closures cannot host `await`. The async pump tasks own the `await transport.send/receive` calls.
`SMBTransport` is `Sendable`; conformers are `final`/actors. `TCPTransportApple` is Apple-only and
isolates its NIO `Channel` to the channel's event loop.

Concretely the bridge has two concurrency layers:
- A **synchronous, lock-guarded byte store** (inlined directly into `TransportBridge` — the
  originally sketched `ByteFIFO` type was not extracted as a separate type; inlining avoids an extra
  abstraction and the dead-code concern) with synchronous `appendInbound`, `enqueueOutbound`,
  `setInboundEOF`, `setInboundError` helpers — callable from C callbacks and from pump tasks.
- **Pump `Task`s** that bridge the byte store to the async `SMBTransport` (see D5). The pump-task
  `Task` references (`outboundPumpTask`, `inboundPumpTask`) are also guarded by the same `NSLock`
  to prevent data races between `startOutboundPump`/`startInboundPump` writes and `close()` reads.

### D4 — Copy at the C/Swift boundary (mandatory)

libsmb2 may free or reuse its `buf` the instant a `send` callback returns. The `send` trampoline
therefore copies bytes out of the C `buf` into owned `Data` **synchronously inside the callback**
(`Data(bytes: buf, count: len)` / `withUnsafeMutableBytes` with no `await` inside the closure) and
returns the count immediately; the async drain happens later from the owned copy. Likewise `recv`
copies *into* the C `buf` synchronously from the inbound FIFO. This mirrors the CLAUDE.md
`RawBuffer` rule ("never check in a buffer libsmb2 may still write into"): we never hand libsmb2 a
buffer that an async task still owns, and we never retain libsmb2's buffer past the callback.
Zero-copy is out of scope.

### D5 — Sync-C ↔ async-Swift bridge mechanics

The bridge is a buffering shim with two FIFOs and two pump tasks:

- **Outbound**: C `send(userdata, buf, len)` copies `buf` → `Data` (D4), `enqueueOutbound(data)`,
  returns `len` immediately. An **outbound pump** `Task` loops: take queued chunks and
  `await transport.send(chunk)`. If nothing is queued it suspends on a continuation that
  `enqueueOutbound` resumes. Backpressure is bounded by the FIFO; libsmb2's own credit/window
  limits keep it small in practice.
- **Inbound**: an **inbound pump** `Task` loops `await transport.receive()` and `appendInbound`s
  the result; an empty `Data` (graceful EOF) calls `markEOF`; a thrown error calls
  `markClosed(error)`. C `recv(userdata, buf, max_len)` synchronously drains up to `max_len` from
  the inbound FIFO into `buf`:
  - bytes available → copy and return the count;
  - empty but open → return the libsmb2 **would-block** signal (negative with `EAGAIN`
    semantics, matching `transport-external.c` reference behavior);
  - empty and EOF → return `0` (peer close);
  - errored/closed → return a negative error.
- Each `appendInbound` (and EOF/close) also fires the **inbound-ready signal** the servicing loop
  waits on (D6).
- **connect**: the C `connect` trampoline kicks off `transport.connect` and blocks the connect
  poll only as long as needed (handled via the servicing loop in D6, since the seam connect is
  itself async). The bridge exposes the connection result to the servicing loop.
- **close**: C `close` (and `SMB2Client` teardown / task cancel) cancels both pump tasks, calls
  `await transport.close()`, marks the FIFO closed, and resumes any suspended pump continuations.

**Trampolines & userdata**: the four C function pointers are top-level/static functions (C
function pointers cannot capture Swift context). The bridge instance is passed as `ext.userdata`
via `Unmanaged.passRetained(bridge).toOpaque()` and recovered in each trampoline with
`Unmanaged<TransportBridge>.fromOpaque(userdata).takeUnretainedValue()`. The single retained
reference is balanced exactly once when the transport is torn down (on `close`/teardown), so the
bridge outlives the libsmb2 context but never leaks — analogous to the existing `CBData`
`passRetained`/`takeRetainedValue` lifetime discipline.

### D6 — No-fd servicing loop (inbound-ready signal + timers)

With an external transport, `smb2_get_fd()` returns `-1`, so `SocketMonitor`/`DispatchSource`
cannot be created and `handleSocketEvent`'s fd-poll is meaningless. The seam replaces fd-readiness
with two wake sources, both serviced on `eventLoopQueue` (invariant preserved):

1. **Inbound-ready**: when the inbound pump appends bytes / EOF / error, it signals the event loop
   (e.g. `eventLoopQueue.async`) to call `smb2_service(context, POLLIN)`. Because there is no fd to
   re-poll, the loop passes `revents` derived from `smb2_which_events(context)` rather than from
   `poll(2)`. Outgoing PDUs are flushed by calling `smb2_service(context, POLLOUT)` after queueing
   an operation when `smb2_which_events & POLLOUT` is set — replacing
   `SocketMonitor.activateWriteSourceIfNeeded`. (libsmb2's `send` callback then pushes those bytes
   into the bridge's outbound FIFO.)
2. **Timers**: after each service pass, query `smb2_get_timeout(context, &tv)`. If a timeout is
   pending, schedule an `eventLoopQueue.asyncAfter(deadline:)` that calls
   `smb2_service_timeout(context)` (drives per-request timeouts now; QUIC handshake/idle/loss-
   recovery later). Reschedule after each pass; cancel on teardown. This replaces the implicit
   timeout that the fd `poll(2)` tick used to provide.

The **connect path** for the seam cannot use `pollUntilComplete`'s `poll(fd)` (fd is -1). Instead
it: sets `ext` via `smb2_set_transport` (D1) before `smb2_connect_share_async`, then drives
servicing via the inbound-ready signal + timer wakes until the connect `CBData` completes, then
proceeds exactly as today (the rest of `async_await`/`generic_handler` is unchanged). All the
existing `CheckedContinuation`, `isAbandoned`, `asyncAfter` timeout, and `withTaskCancellationHandler`
machinery is reused verbatim — only the *byte transport and wake source* differ.

**Opt-in selection**: `SMB2Client.connect` (and the `SMB2Manager` connect surface) gains an
optional `SMBTransportKind`. Default (`nil` / legacy) → unchanged `DispatchSource` path,
byte-for-byte. When a seam kind is supplied on Apple → build `TCPTransportApple`, wrap it in
`TransportBridge`, `smb2_set_transport(ctx, AUTO, ext)`, and run the no-fd loop.

### D7 — Apple-only seam vs Linux legacy

`NIOTransportServices` is Network.framework-backed (Apple-only). All NIO/seam transport code lives
behind `#if canImport(Network)`. On Linux, `SMBTransportKind` selection of a seam transport is
unavailable and `SMB2Client` always uses the legacy libsmb2-owned TCP `DispatchSource` path; the
Linux build never references NIO symbols. The pure-Swift seam protocol + bridge *could* compile on
Linux, but with no `TCPTransportApple` there is no production conformer there, so we keep the bridge
build-guarded with the servicing loop to avoid dead Linux code (only `MockTransport` exercises it in
tests).

### D8 — Opt-in then flip (rollout)

1. **Opt-in (T1–T7, #20–#26)**: seam ships selectable via `SMBTransportKind`; default stays legacy.
2. **Acceptance (T8, #27)**: run the full Docker Samba integration suite *both* ways (legacy +
   seam) — connect, NTLM auth, directory listing, large read, large write, cancel/timeout — and
   confirm identical outcomes; add a CI leg exercising the seam.
3. **Flip (T9, #28)**: only after #27 is green, make `TCPTransportApple` the Apple default and
   **delete** the now-dead Apple `SocketMonitor`/`DispatchSource` read/write sources and fd
   servicing (CLAUDE.md same-task dead-code rule). Linux retains the legacy path under `#if`.

### D9 — NIO in the main target

SwiftNIO + NIOTransportServices are added to the existing `AMSMB2` target (not a separate product);
consumers link NIO whether or not they opt into the seam. Apache-2.0 (NIO) is App-Store-compatible
and recorded alongside the libsmb2 LGPL note. Pin to a current stable major
(`swift-nio` 2.x, `swift-nio-transport-services` 1.x). `NIOCore` is the only hard NIO dependency of
production code; `NIOPosix` is added only if a test needs `EmbeddedChannel`/loopback.

## Risks / Trade-offs

- **[Bridge deadlock / starvation]** If the outbound pump never runs while libsmb2 waits to flush,
  a request can stall. → Pump tasks are independent of `eventLoopQueue`; outbound enqueue resumes
  the pump immediately; servicing is re-triggered on every inbound append and after each
  `smb2_service` pass. Validated by the mock full-exchange test (#25).
- **[Buffer lifetime / use-after-free]** → D4 copy-at-boundary, verified by a bridge unit test that
  overwrites the C buffer right after `send` returns and asserts the sent bytes are intact.
- **[Double-resume / leak on cancel]** → Reuse the proven `CBData` `isAbandoned` +
  `passRetained`/`takeRetainedValue` discipline; the bridge's single retained ref is balanced once
  on teardown. Cancellation test asserts clean teardown.
- **[Timer drift vs fd poll]** The old fd `poll(2)` tick implicitly bounded waits; the new loop must
  arm `smb2_service_timeout` correctly or requests could hang. → Spec requires a timer-driven
  timeout path test (#25) using a mock that never replies.
- **[Naming-trap regression]** Selecting `SMB2_TRANSPORT_TCP` for the seam silently uses the
  built-in socket and ignores `ext`. → Code comment + a servicing test that asserts the external
  selector (AUTO/QUIC) is used and `smb2_get_fd()` returns -1 under the seam.
- **[Behavior drift vs legacy]** → The flip (#28) is gated on #27 proving no observable difference
  across the full acceptance matrix, run both ways.

## Migration

No consumer migration. Internally: T9 removes the Apple legacy `SocketMonitor`/`DispatchSource`
code in the same task that flips the default; Linux behavior is unchanged. The public `SMB2Manager`
API is identical before and after.

## Open Questions

- Exact submodule SHA to pin in T1 (the fork `master` head containing `smb2_set_transport` at
  implementation time).
- Whether `automatic` should prefer the seam on Apple and legacy on Linux, or always map to the
  external selector on Apple — resolve when wiring T6/T9; default assumption: Apple seam, Linux legacy.
