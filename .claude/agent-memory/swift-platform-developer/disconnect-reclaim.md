# CBData / smb2_context ownership (Context.swift)

Established by `fix-cbdata-cancel-race-uaf` and `fix-disconnect-reclaims-context`.

## Retain rules

- Once a PDU is queued (`smb2_*_async` / `smb2_queue_pdu` succeeded), libsmb2 owns the
  `Unmanaged.passRetained(cb)` `+1`. Only `generic_handler`'s `takeRetainedValue()` balances it —
  on the reply, or during `smb2_destroy_context`'s teardown sweep. Never `release()` after queuing.
- Therefore the ONLY way to reclaim a pending `CBData` whose reply never arrives is to destroy the
  context. `disconnect()` does this now (`failPendingAndDestroyContext(with:)`), not just `deinit`.
- `TransportBridge.makeExternalTransport()` hands libsmb2 a `+1` via `ext.userdata`, consumed ONLY
  by the C `ext.close` trampoline, which libsmb2 calls from `smb2_destroy_context`. `teardownSeam()`
  calls the *Swift* `bridge.close()` and does NOT balance it — destroying the context does.

## Ordering invariant (load-bearing)

`failPendingAndDestroyContext(with:)` is exactly `failAllPendingOperations(with:)` then the
`if let`-guarded `destroyContext` + `context = nil`, adjacent and in that order. Abandoning first
makes every destroy-fired callback take `generic_handler`'s `isAbandoned` early return, which is
what keeps the `[weak self]` capture in the `cb.dataHandler` wrappers from ever being observed nil
during `deinit` (Swift zeroes weak refs once dealloc starts). The `if let` is required because
`flushOutboundForSeam` / `smb2_service` can destroy the context on error first.

`disconnect()` ordering: PDU flush (needs the live bridge) -> `teardownSeam()` /
`stopSocketMonitoring()` -> helper(`ENOTCONN`). `shutdown()`: transport teardown -> fd-path
best-effort PDU -> helper(`ECANCELED`).

## Testing the lifetime

- `SMB2Client.CBData.liveCount` — lock-guarded live-instance counter. Assert BASELINE-relative,
  never `== 0`; other tests in the process hold live instances.
- The per-operation timeout timers in `async_await` / `async_await_pdu` / `connectWithBridge`
  capture `cb` STRONGLY, so with `timeout > 0` an emptied `CBData` shell survives until the timer
  fires. Any test asserting `liveCount == baseline` right after `disconnect()` must use
  `SMB2Client(timeout: 0)`; integration tests must poll with a deadline > `timeout`.
- `smb2_echo_async` queues fine on a never-connected context (no session/transport/credit
  precondition) — the cheapest way to get a pending PDU with no server.
- `pendingSeamOperationCount` is platform-neutral (moved out of `#if canImport(Network)`);
  `hasInstalledSeamBridge` is seam-only.
- New tests live in `AMSMB2Tests/SMB2DisconnectReclaimTests.swift` (platform-neutral, seam parts in
  a gated extension). `SMB2CBDataLifetimeTests.swift` is wholly inside `#if canImport(Network)`.
