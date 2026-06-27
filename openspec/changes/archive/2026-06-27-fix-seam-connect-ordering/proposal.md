## Why

The pluggable TCP transport seam (`add-pluggable-tcp-transport`, T1–T9) is wired end to end:
on Apple every connection now routes through `TransportBridge` →
`TCPTransportApple` (`NIOTransportServices`). Unit tests and the no-fd servicing loop pass, but
**every real-SMB integration test fails on Apple** — the seam never completes a handshake against
a live Samba server. This change fixes that defect. It is the gate that lets the
`feat/tcp-transport-rollout` branch ship a working Apple seam.

### Confirmed root cause (diagnosed against live Samba with instrumentation)

The bridge tells libsmb2 the connection is established **before** the async TCP connect actually
completes. The proven sequence:

1. `TransportBridge.makeExternalTransport()`'s `ext.connect` trampoline calls
   `kickConnect(host:port:)`, which does `Task { try? await transport.connect(...) }` — a
   **detached** task whose error is **swallowed** — and returns `0` immediately.
2. libsmb2 `transport-external.c` `ext_connect` treats a `0` return as *"connection immediately
   established"*: it sets `ext_connected = 1` and **synchronously** fires `connect_cb`, starting
   NEGOTIATE (`transport-external.c:144-159`).
3. The outbound pump calls `TCPTransportApple.send()` while `_channel` is still `nil` →
   `POSIXError(.ENOTCONN, "Socket is not connected")` (errno 57). The inbound `receive()` fails
   the same way.
4. The handshake collapses; libsmb2 invokes the connect completion with status `-1`, which
   `Context.swift` maps via `-(-1) = 1` to `POSIXError(.init(1))` == `EPERM`
   "Operation not permitted" — the symptom the user sees.
5. By the time the detached connect `Task` finally runs, the bridge is torn down:
   `EventLoopError: the event loop is shutdown`.

**The network layer is healthy.** A bare `NWConnection` and `TCPTransportApple.connect()` to
`127.0.0.1:445` both succeed in ~5 ms. The defect is purely the **connect/handshake ordering** at
the bridge ↔ transport boundary, not the transport implementation.

## What Changes

- **Establish the transport before libsmb2 starts the handshake (Approach A — eager connect).**
  The architect selected **Approach A** (design.md → D-FIX-1; Approach B, a blocking trampoline,
  was rejected because it would park `eventLoopQueue` on the TCP handshake RTT). The fix
  `await`s `bridge.connect(host:port:)` in `connectWithBridge` *before* `smb2_set_transport` /
  `smb2_connect_share_async`, so by the time `ext_connect` fires `connect_cb` (NEGOTIATE),
  `TCPTransportApple` has a live `_channel` and the first outbound `send()` / inbound `receive()`
  succeed. The `ext.connect` C trampoline becomes a state-reporting no-op
  (`return isPreConnected ? 0 : -ECONNREFUSED`) that performs **no** second connect; the
  fire-and-forget `Task { try? await … }` in `kickConnect` is deleted. `connectWithBridge` parses
  host/port from `server` mirroring `ext_connect`'s rules (the same string libsmb2 parses).
- **Stop swallowing connect errors.** A failed transport connect must surface as the connect
  operation's thrown error (mapped `POSIXError`), not as a downstream `EPERM`/`ENOTCONN` or a
  silent detached-task failure.
- **Make the seam integration suite the regression gate.** `SMB2SeamIntegrationTests` (connect +
  NTLM, listing, large read/write, cancel/timeout) must pass against live Samba through the seam,
  and the no-fd invariant (`smb2_get_fd == -1`) must hold throughout.

### Non-Goals

- **No transport rewrite.** `TCPTransportApple`, the pump architecture, the no-fd servicing loop,
  and the `Unmanaged` userdata discipline are unchanged except where the chosen approach touches
  the connect ordering.
- **No public API change.** `SMB2Manager`'s surface is unchanged.
- **No Linux change.** Linux keeps the legacy libsmb2-owned TCP path under
  `#if !canImport(Network)`; the bug and fix are Apple-seam-only.
- **No QUIC.** Out of scope.

## Capabilities

### Modified Capabilities

- `transport-bridge`: the `ext.connect` trampoline now reports the result of the eager
  `connect(host:port:)` (`connectStatus()` → `0` only when the channel is live), instead of a
  fire-and-forget kick that always returned `0`. Connect errors propagate via the eager
  `await` instead of being swallowed.
- `transport-servicing`: `connectWithBridge` orders transport establishment ahead of the libsmb2
  handshake so the first serviced send/recv always has a live channel.

### New Capabilities

- `transport-connect-ordering`: the testable readiness invariant — when libsmb2 begins NEGOTIATE
  through the seam, the transport is already connected; a failed connect surfaces as the connect
  call's thrown error; the full seam acceptance matrix (connect/NTLM, list, large I/O,
  cancel/timeout) succeeds with `smb2_get_fd == -1` throughout.

## Impact

- **`AMSMB2/TransportBridge.swift`**: added `connect(host:port:)` (sets `isPreConnected` under the
  lock) and `connectStatus()`; the `ext.connect` trampoline now returns `connectStatus()`
  (no-op-when-pre-connected); the fire-and-forget `kickConnect` is removed.
- **`AMSMB2/Context.swift`** (`connectWithBridge`, ~line 1070): parses host/port from `server`
  (`parseSeamEndpoint`, mirroring libsmb2's `[ipv6]:port` / `host:port` / default-445 rules) and
  `await`s `bridge.connect(...)` before `smb2_set_transport`; a connect failure is mapped to a
  thrown `POSIXError` (`mapTransportConnectError`) with no operation registered. The two
  early-failure guards (`context == nil`, `smb2_set_transport != 0`) now also close the
  eagerly-connected transport so the live channel does not leak.
- **`AMSMB2/AMSMB2.swift`**: the `smbClient` accessor now gates on the seam-aware `isConnected`
  predicate instead of `fileDescriptor != -1` (a seam connection owns no native fd).
- **`AMSMB2/TCPTransportApple.swift`**: unchanged (the connect path already works).
- **T8/T9 sequencing reconciliation**: T8.3 ("run both legacy vs seam, confirm identical") is
  **impossible on Apple** because T9 already removed the legacy Apple path (Apple is seam-only).
  This change documents and resolves that honestly (see `design.md` "T8/T9 reconciliation") so the
  rollout artifacts stay truthful: the A/B equivalence claim is re-scoped to *Linux legacy vs
  Apple seam against the same server*, and the Apple acceptance criterion becomes *the seam suite
  passes*, not *seam matches a (now non-existent) Apple legacy path*.
- **Threading / concurrency**: unchanged isolation model (`eventLoopQueue`-serialized,
  continuation-based). The eager `await` runs on the caller's task (the async function body,
  before the `eventLoopQueue.async` continuation block), so it blocks no serialized work.
- **Tests**: `SMB2SeamIntegrationTests` is the red→green gate; a Docker-backed live Samba run is
  the acceptance evidence.
