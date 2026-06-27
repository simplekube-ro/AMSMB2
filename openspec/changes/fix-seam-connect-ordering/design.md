## Context

The transport seam is fully wired (`add-pluggable-tcp-transport`, archived T1–T9). The relevant
moving parts:

- **`AMSMB2/Context.swift` `connectWithBridge(server:share:user:bridge:)`** (~line 1070) runs on
  `eventLoopQueue`. It calls `smb2_set_transport(context, SMB2_TRANSPORT_AUTO, &ext)`, asserts
  `smb2_get_fd(context) == -1`, sets the libsmb2 timeout, installs the inbound-ready handler,
  then calls `smb2_connect_share_async(...)`, starts the bridge pumps, and flushes outbound.
- **`AMSMB2/TransportBridge.swift` `makeExternalTransport()`** populates the four C trampolines.
  The `ext.connect` trampoline calls `kickConnect(host:port:)`:

  ```swift
  func kickConnect(host: String, port: Int) {
      let connectingTransport = transport
      Task { try? await connectingTransport.connect(host: host, port: port) }   // detached, error swallowed
  }
  ```

  and the trampoline returns `0` unconditionally.
- **libsmb2 `lib/transport-external.c` `ext_connect`** (lines 91–160): parses `server` into
  host/port (`[ipv6]:port` / `host:port` / default `445`, no name resolution), calls
  `smb2->ext.connect(userdata, host, port)`, and — critically — on a **`>= 0`** return:

  ```c
  smb2->ext_connected = 1;
  smb2->connect_cb = cb;  smb2->connect_data = cb_data;
  smb2->connect_cb(smb2, 0, NULL, smb2->connect_data);   // fires NEGOTIATE synchronously
  return 0;
  ```

  On a **`< 0`** return it sets the error and returns `ret` (the connect is aborted, NEGOTIATE is
  never started).
- **`AMSMB2/TCPTransportApple.swift`** holds `_channel` under an `NSLock`; `connect(host:port:)`
  is async (NIOTS `connect().get()`) and only assigns `_channel` once the channel is active.
  `send()`/`receive()` throw `POSIXError(.ENOTCONN)` while `_channel` is `nil`.

### The bug, precisely

`kickConnect` returns `0` to `ext_connect` **before** `_channel` exists. `ext_connect` reads `0`
as "established", sets `ext_connected = 1`, and synchronously fires `connect_cb` → NEGOTIATE →
outbound pump `send()` → `ENOTCONN`. The detached connect `Task` runs later, swallows its error,
and (on failure) finds the event loop already shut down. So the contract libsmb2 relies on — *a
`>= 0` connect return means the transport can carry bytes now* — is violated.

The fix must make that contract true: **the transport is connected before any `>= 0` is reported
to `ext_connect`** (equivalently, before NEGOTIATE is allowed to start), and **a connect failure
is reported as `< 0` / a thrown error**, not swallowed.

## Goals / Non-Goals

**Goals**
- When libsmb2 fires `connect_cb` (NEGOTIATE), `TCPTransportApple._channel` is live so the first
  `send()`/`receive()` succeed.
- A transport connect failure surfaces as the `connect(...)` call's thrown `POSIXError`, with the
  seam torn down and no operation registered.
- `SMB2SeamIntegrationTests` passes against live Samba; `smb2_get_fd == -1` holds throughout.
- No change to the no-fd servicing loop, pump architecture, or `Unmanaged` discipline beyond the
  connect ordering.

**Non-Goals**
- No public API change; no Linux change; no QUIC; no transport rewrite.

## Architect Decision (2026-06-26, review gate)

### D-FIX-1 — Approach: **A (eager connect)**. Approach B is rejected.

**What:** Establish the transport with `await … connect(host:port:)` in `connectWithBridge`
*before* `smb2_set_transport` / `smb2_connect_share_async`. The `ext.connect` C trampoline becomes
a state-reporting no-op (`return isPreConnected ? 0 : -ECONNREFUSED`) that performs **no** second
connect. The detached `Task { try? await … }` in `kickConnect` is deleted.

**Why (decisive factors):**
1. **Event-loop blocking is disqualifying for B.** `ext_connect` runs inside the
   `eventLoopQueue.async` block (it is called synchronously from `smb2_connect_share_async`). B's
   `semaphore.wait()` therefore parks `eventLoopQueue` — the single serial queue that owns *all*
   libsmb2 access and services every connection, timer, and inbound-ready callback — on a TCP
   handshake RTT. This is a direct violation of the project's core invariant ("never block the
   serialized context; no `DispatchSemaphore` inside it"). A's `await` runs on the caller's task
   executor (the async function body, *before* the `withCheckedThrowingContinuation`/
   `eventLoopQueue.async` block), so it blocks nothing.
2. **Correctness / liveness.** B is correct only in the happy path; under cooperative-pool
   starvation or any future transport that schedules continuation work back onto `eventLoopQueue`,
   `wait()` deadlocks with no timeout. A has no such failure mode.
3. **Cancellation & error propagation.** A keeps full `withTaskCancellationHandler` responsiveness
   and natural `throw` propagation; B loses cancellation on the parked thread and launders the
   error through a lock-guarded result box.
4. **Parsing-duplication objection against A is weaker than it looks.** The `server` string A
   parses is the *identical* string libsmb2 later hands to `ext_connect` (both read
   `smb2->server`, set from the `smb2_connect_share_async` server arg — verified in
   `Context.swift:1137` and `transport-external.c`). So only the parse *logic* must match, not any
   input normalization, and the real connection endpoint is solely the Swift parse (the trampoline
   discards libsmb2's parsed host/port). The C-mirrored unit-test table fully pins this.

A trades a small, test-pinnable parser for full alignment with the project's no-blocking
concurrency model. That trade is correct.

### D-FIX-2 — Sequencing: **Apple stays seam-only (option i)**. Do NOT restore a legacy Apple path.

**What:** Accept that T9 already removed the legacy Apple transport (Apple is seam-only) and
re-scope the T8.3 "legacy vs seam, identical" claim to **Linux legacy (libsmb2 built-in TCP) vs
Apple seam, same Samba server, same assertions**. The Apple acceptance criterion becomes "the seam
suite is green against live Samba", not "seam matches a (now non-existent) Apple legacy path".

**Why:** Re-introducing `SocketMonitor`/`pollUntilComplete` on Apple purely to satisfy a
one-platform A/B comparison would (a) reinstate code T9 deliberately deleted — a dead-code
reintroduction the project explicitly forbids; (b) contradict the entire rollout goal (Apple →
seam-only); and (c) buy nothing the cross-platform oracle does not already provide. Linux CI still
exercises the libsmb2 built-in TCP path against the *same* Samba fixture and the *same* test
assertions, so the behavioral contract (identical listings, byte-exact I/O, same `POSIXError`
mapping) is validated across the platform split. Restoring legacy-on-Apple is rejected.

### Correctness mandates the implementer MUST honor (binding conditions of approval)

1. **Encapsulation:** `TransportBridge.transport` is `private`. Do NOT widen it. Add an
   `internal func connect(host:port:) async throws` (or `connectTransport`) on the bridge that
   calls `transport.connect` and sets an internal `isPreConnected` flag under `lock`. Context calls
   *that*, not `bridge.transport` directly. This keeps the bridge's lifetime/ownership contract intact.
2. **Teardown-on-early-failure leak (THE key A risk):** once `await … connect()` succeeds the
   channel is live, but the C `close` trampoline only fires if libsmb2 owns the `ext` struct.
   Therefore every failure path in `connectWithBridge` that returns *after* a successful transport
   connect but *before* a wired close trampoline must explicitly close the transport. Concretely:
   the `context == nil` guard (Context.swift:1091) and the `smb2_set_transport != 0` guard
   (Context.swift:1104) currently only release the `Unmanaged` and throw — they will now leak an
   open channel. Both must additionally tear the transport down (e.g. `await bridge.close()` /
   `transport.close()`), and the spec's "bridge torn down, no operation registered" scenario must
   cover them. The `smb2_connect_share_async < 0` path (1141) and the cancel/abandoned/timeout
   paths already route through `teardownSeam() → bridge.close() → transport.close()` once
   `transportBridge` is set, so those are fine.
3. **Exactly-once connect:** `ext.connect` must NOT call `transport.connect` again. Guard via
   `isPreConnected`. Calling `TCPTransportApple.connect` twice would open a second channel.
4. **Once-semantics `ext_close` contract is unchanged** and must stay intact: the
   `passRetained(self)` in `makeExternalTransport()` is still consumed exactly once by
   `takeRetainedValue()` in the close trampoline. A's early-failure teardown (mandate 2) closes the
   *transport/channel* but must continue to balance the bridge `Unmanaged` exactly as the existing
   code does on the `set_transport`-fail path — do not double-release.
5. **Trampoline return value:** change the `ext.connect` trampoline from the hardcoded `return 0`
   to return `kickConnect(...)`'s `Int32`, and update `kickConnect`'s stale doc comment ("connect
   result is ignored here; T6's servicing loop handles connect errors" — now false).

### Decisions recorded for tasks.md

C0.1/C0.2 are satisfied by this section: Approach A is selected; proposal.md "What Changes" must
drop Approach B and state A. T8/T9 reconciliation follows option (i).

---

## Approach analysis (retained for the record)

Two approaches make the contract true. The architect selected **A** above; both are kept here for
traceability.

---

### Approach A — Eager connect (connect in `connectWithBridge` before the handshake)

**Idea**: establish the transport in Swift *before* handing the bridge to libsmb2. Make the
`ext.connect` trampoline a no-op that reports the already-known state.

**Sketch**

1. In `connectWithBridge`, before `smb2_set_transport`, parse host/port from `server` (replicating
   libsmb2's rules: strip `[...]` for IPv6, split on the last `:`, default port `445` — see
   "Host/port parsing" below) and:

   ```swift
   do {
       try await bridge.transport.connect(host: parsedHost, port: parsedPort)
   } catch {
       throw SMB2Client.mapTransportConnectError(error)   // POSIXError; no operation registered
   }
   ```

   This `await` happens on the structured-concurrency task **before** entering the
   `eventLoopQueue.async` continuation block — so it does not block the event loop thread.
2. The bridge records `isPreConnected = true`. `kickConnect` (now `ext.connect`) becomes:

   ```swift
   func kickConnect(host: String, port: Int) -> Int32 {
       // Transport was already established by connectWithBridge; nothing to do.
       return isPreConnected ? 0 : -ECONNREFUSED
   }
   ```

   so `ext_connect` reads `0` and fires NEGOTIATE into a live channel.
3. The existing `eventLoopQueue.async` block (set_transport → connect_share_async → pumps →
   flush) is unchanged. Pumps may even be started right after the successful `await connect` so
   the inbound pump is already parked in `receive()` when NEGOTIATE's response arrives.

**Trade-offs**

- *Pros*
  - The `await` runs on the caller's task, never on `eventLoopQueue` — **zero event-loop blocking
    risk**, no semaphore, no deadlock surface.
  - Connect errors propagate naturally via `throw`/`try await`; nothing is swallowed.
  - The ordering is explicit and linear; trivial to reason about and to assert in tests
    ("`_channel` non-nil before `smb2_connect_share_async`").
  - Matches the legacy path's spirit: connect first, then start servicing.
- *Cons*
  - **Host/port parsing is duplicated** in Swift and must stay byte-for-byte compatible with
    `ext_connect`'s parser (IPv6 `[...]`, missing-`]` error, default 445). Divergence = connecting
    to the wrong endpoint. Mitigation: a focused unit test table mirroring the C cases; keep the
    parser in one private helper.
  - `ext.connect` no longer "drives" the connect — it only reports state. Slightly surprising for a
    reader who expects the C callback to do the work. Mitigation: doc comment + the
    `isPreConnected` name.
  - If a future transport (QUIC) wants libsmb2 to choose/resolve the address, the eager model would
    need revisiting. (Out of scope now; AUTO already hands host/port verbatim with no resolution.)

---

### Approach B — Blocking trampoline (synchronously wait inside `kickConnect`)

**Idea**: keep `ext.connect` as the thing that performs the connect, but make it **synchronous**:
block the trampoline until the async connect resolves, then return the real `0` / `-1`.

**Sketch**

```swift
func kickConnect(host: String, port: Int) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = ResultBox()                  // @unchecked Sendable, lock-guarded
    let connectingTransport = transport
    Task.detached {
        do { try await connectingTransport.connect(host: host, port: port); resultBox.set(.success) }
        catch { resultBox.set(.failure(error)) }
        semaphore.signal()
    }
    semaphore.wait()                              // <-- blocks the calling thread
    switch resultBox.value {
    case .success:           return 0
    case .failure:           return -ECONNREFUSED
    }
}
```

`ext_connect` then reads a truthful status: `0` → fire NEGOTIATE into a live channel; `< 0` →
abort the connect and propagate the error up through `smb2_connect_share_async`.

**Trade-offs / risk analysis (event-loop-thread blocking)**

- **Who is the calling thread?** `ext_connect` is called from `smb2_connect_share_async`, which in
  `connectWithBridge` runs **inside `eventLoopQueue.async`** — i.e. on `eventLoopQueue`, the single
  serial queue that owns all libsmb2 access. `semaphore.wait()` therefore **blocks
  `eventLoopQueue`**.
- **Deadlock surface**: the async connect (`TCPTransportApple.connect`) completes on a NIOTS
  `EventLoopGroup` thread — a *different* executor from `eventLoopQueue` — so the semaphore can be
  signalled while `eventLoopQueue` is parked. That avoids the classic self-wait deadlock **in the
  happy path**. But:
  - The Swift concurrency thread pool is finite. If the connect's continuation chain ever needs to
    hop onto a thread that is itself blocked (e.g. cooperative-pool starvation under load, or if a
    transport implementation ever schedules work back onto `eventLoopQueue`), `wait()` deadlocks
    with no timeout.
  - While parked, `eventLoopQueue` services **nothing** — no other connection, no timer, no
    inbound-ready callback can run. Connect latency (TCP handshake, ~RTT) directly stalls the one
    queue the whole client depends on. This is exactly the "never block an actor's executor" /
    "no `DispatchSemaphore` inside the serialized context" rule the project enforces (CLAUDE.md,
    Context serialization model).
  - A misbehaving/black-holed server makes `connect` hang; without a timeout the queue is stuck
    forever. A bounded `semaphore.wait(timeout:)` is mandatory, which reintroduces the timeout
    bookkeeping the async path already does — duplicated and harder to cancel.
  - `withTaskCancellationHandler` cannot interrupt a thread parked in `semaphore.wait()`;
    cancellation responsiveness during connect is lost.
- *Pros*
  - **No host/port parsing duplication** — libsmb2 parses `server` and hands host/port to the
    trampoline, exactly as today. The seam stays "libsmb2 drives connect".
  - Localized change: only `kickConnect` changes; `connectWithBridge` ordering is untouched.
- *Cons*
  - Blocks the serial event-loop queue on network I/O (the central objection); needs a bounded
    timeout to be safe; weakens cancellation; adds a semaphore + lock-guarded result box
    (`@unchecked Sendable`) that the project style otherwise avoids.

---

### Comparison summary (for the architect)

| Dimension | A — Eager connect | B — Blocking trampoline |
|---|---|---|
| Event-loop blocking | None (await on caller task) | **Blocks `eventLoopQueue`** during connect |
| Deadlock risk | None | Low in happy path, real under pool starvation / re-entrancy; needs timeout |
| Cancellation during connect | Full (`try await` + handler) | Lost (parked thread) |
| Error propagation | Natural `throw` | Real `-1`, but mapped from a boxed result |
| Host/port parsing | **Duplicated in Swift** (must match C) | Reuses libsmb2's parser |
| Change blast radius | `connectWithBridge` + small bridge flag | `kickConnect` only |
| Fit with project rules | Aligns ("no blocking", structured concurrency) | Conflicts ("no semaphore in serialized context") |

Both satisfy the spec's readiness invariant. A trades a small, test-pinnable parsing duplication
for full alignment with the project's no-blocking concurrency model; B trades parser reuse and a
tiny diff for blocking the central serial queue on network I/O. **Architect to decide.**

### Host/port parsing (applies to Approach A only)

If A is chosen, the Swift parser MUST mirror `ext_connect` exactly:
- Leading `[` → IPv6 literal; host is up to the matching `]`; a missing `]` is an error
  (`POSIXError(.EINVAL)`), matching the C path.
- After the (optional) `]`, the **first** `:` separates host from port; the remainder is parsed as
  an integer port.
- No `:` → default port `445`.
- No DNS resolution — host string handed verbatim to `transport.connect`.
A unit-test table covers: `host`, `host:1445`, `[::1]`, `[::1]:1445`, `[bad` (error), and IPv4
`127.0.0.1:445`.

## T8/T9 reconciliation (keeping rollout artifacts honest)

The archived rollout left a contradiction this change must resolve so artifacts match reality:

- **T9** already made Apple **seam-only**: the legacy `connect(server:share:user:)` and
  `SocketMonitor`/`pollUntilComplete` are compiled `#if !canImport(Network)` (Linux-only), and
  `SMB2Manager.connect` routes to `transportKind: .automatic` on Apple. **There is no Apple legacy
  transport to compare against.**
- **T8.3** ("run both ways — legacy vs seam — confirm identical behavior") therefore **cannot be
  executed on Apple**. Its premise (two coexisting Apple transports) no longer holds.

Resolution (to be reflected in the archived rollout artifacts when this change lands, so they stay
truthful — CLAUDE.md "keep specs honest"):

1. **Re-scope the equivalence claim.** "Legacy vs seam, identical" is validated as **Linux legacy
   vs Apple seam against the same Samba server and the same test assertions**, not as two
   transports on one platform. The behavioral contract (same listings, same byte-exact I/O, same
   error mapping) is what must match, across the platform split.
2. **Restate the Apple acceptance criterion.** On Apple, "passes" means **the seam integration
   suite (`SMB2SeamIntegrationTests`) is green against live Samba** — not "seam output matches a
   (now removed) Apple legacy path".
3. **Annotate T8.3** in the rollout `tasks.md` as superseded-by-`fix-seam-connect-ordering`, with a
   pointer here, rather than leaving it checked-but-false. (Edit limited to a clarifying note;
   no behavior is rewritten.)

This keeps the no-dead-claim invariant: nothing in the artifacts asserts an Apple legacy path that
does not exist.

## Risks

- **Approach A parsing drift** — mitigated by the C-mirrored unit-test table and a single helper.
- **Approach B queue stall / deadlock** — the central risk; if B is chosen, a bounded
  `wait(timeout:)` and an explicit deadlock argument are mandatory.
- **Hidden second connect** — whichever approach, ensure the transport is connected **exactly
  once**: in A, `ext.connect` must not re-connect; in B, `connectWithBridge` must not also connect.
- **Teardown on connect failure** — the seam (`transportBridge`, inbound-ready handler,
  `smb2_set_transport` install) must be fully torn down and no operation registered when connect
  fails, mirroring the existing `teardownSeam()` error paths.
