## Context

See proposal.md — Why. Current state that shapes the approach:

- `SMB2Client` owns one `smb2_context`; only `shutdown()` (called from `deinit`) and the three
  `smb2_service` error paths (`Context.swift:349`, `:1710`, `:1738`) call `smb2_destroy_context`
  and nil `self.context`. `disconnect()` (`:639`) does neither.
- `shutdown()` (`:189`) already performs the exact sequence this change needs, on
  `eventLoopQueue`: `teardownSeam()` / `socketMonitor.cancel()` → `failAllPendingOperations` →
  best-effort disconnect PDU (fd path only) → `destroyContext` → `context = nil`. `deinit`
  guards on `context != nil`, so a client whose context was already destroyed skips `shutdown()`.
- `smb2_destroy_context` (`Dependencies/libsmb2/lib/init.c:313`) calls `transport->close`, then
  fires every `outqueue` / `pdu` / `waitqueue` callback with `SMB2_STATUS_SHUTDOWN`, then
  `connect_cb`. The seam `ext.close` trampoline (`TransportBridge.swift:231`) is nil-safe and
  once-only, and `teardownSeam()` has already closed the bridge. `generic_handler` (`:866`)
  does `takeRetainedValue()` then early-returns on `isAbandoned` — that early return currently
  skips `cleanup = nil` / `dataHandler = nil`.
- **`teardownSeam()` alone never balances the bridge retain.** `makeExternalTransport()`
  (`TransportBridge.swift:200-204`) hands libsmb2 a `+1` on the `TransportBridge` through
  `ext.userdata`; the ONLY thing that consumes it is the C `ext.close` trampoline
  (`TransportBridge.swift:231`), which libsmb2 invokes from `smb2_destroy_context`'s
  `transport->close` call (`init.c:319-321`). `teardownSeam()` (`Context.swift:1795`) nils
  `transportBridge` and calls the *Swift* `bridge.close()` — it never reaches `ext_close`. So
  today `disconnect()` also strands the `TransportBridge` (and its `TCPTransportApple` / NIO
  channel) until the client's `deinit`, which the retain cycle makes unreachable. Destroying the
  context in `disconnect()` (D-1) fixes this leak too, and gives the tests a second, cheap
  observable: a `weak` reference to the bridge must go nil after `disconnect()`.
- Ownership invariant from `fix-cbdata-cancel-race-uaf` (spec `operation-cancellation-lifetime`):
  once a PDU is queued the `CBData` `+1` is balanced only by `generic_handler`; abandon paths
  must never release it. This change does not touch that rule — it only ensures the callback
  actually fires (destroy at disconnect) and that the object graph hanging off `CBData` cannot
  pin the client while waiting.
- `async_await` / `async_await_pdu` wrap the caller's `dataHandler` in a closure that captures
  `self` strongly (`:916`, `:1024`) — verified: the wrapper body calls `dataHandler(self, ptr)`.
  The seam connect path's `cb.cleanup` (`:1601`) captures `cb` itself (it reads `cb.result`),
  which is a genuine self-retain: `generic_handler` clears `cleanup` only on the *non*-abandoned
  branch, so an abandoned connect `CBData` survives forever once libsmb2 has released its retain.
  The `async_await` / `async_await_pdu` `cb.cleanup` closures already use `[weak self]` (`:958`,
  `:1066`) and capture nothing else, so D-3 matters mainly for the connect path and for releasing
  whatever the caller's `dataHandler` captured.
- Existing deterministic test infrastructure: `SMB2CBDataLifetimeTests` (gated / never-reply
  transport, drives real `connectWithBridge`), `MockTransport(sendsAreDropped:)`,
  `pendingSeamOperationCount` / `hasInstalledSeamBridge` internal test accessors.

## Goals / Non-Goals

**Goals:**
- Every pending `CBData` is balanced (freed) before `disconnect()` returns, on both the seam and
  fd paths, with the retain balanced exactly once (no regression of PR #48).
- A pending or abandoned operation can never keep its `SMB2Client` alive (no cycle through
  libsmb2's queues), independently of whether `disconnect()` is ever called.
- One teardown sequence shared by `deinit` and `disconnect()`, not a third copy.
- Deterministic, server-less regression tests that fail on the current code.

**Non-Goals:**
- Reclaiming the intentionally abandoned `RawBuffer` per cancelled read.
- Making a disconnected `SMB2Client` reconnectable.
- Sending the seam disconnect PDU from `deinit` (fd path already does; leave the asymmetry).
- Any change to `SMB2Manager`'s connect/disconnect state machine.

## Decisions

**D-1: `disconnect()` destroys the context by reusing `shutdown()`'s tail; ordering is fixed.**
Extract the common tail of `shutdown()` — `failAllPendingOperations(with:)` then
`if let ctx = context { Self.destroyContext(ctx); context = nil }` — into a private
event-loop-confined helper taking the failure error. `shutdown()` calls it with `ECANCELED`
(after its existing fd-path PDU emission); `disconnect()` calls it with `ENOTCONN` after its
existing platform-specific PDU emission and transport teardown. Required ordering, which both
callers already satisfy and which MUST be preserved:
1. best-effort disconnect PDU + flush — on the seam this MUST precede `teardownSeam()` because
   `flushOutboundForSeam` needs the live bridge;
2. `teardownSeam()` (Apple) / `stopSocketMonitoring()` (fd) — so no inbound bytes or timers can
   re-enter `smb2_service` after this point;
3. `failAllPendingOperations` — sets `isAbandoned` on every pending `CBData` **before** step 4 so
   the destroy-fired callbacks early-return instead of double-resuming a continuation;
4. `destroyContext` + `context = nil`, guarded by `if let` because `flushOutboundForSeam` /
   `smb2_service` can themselves destroy the context on error (`:1738`) before the tail runs.

The extracted helper is EXACTLY these two statements, in this order, and nothing else:

```swift
/// Fails every pending operation with `error` (marking each abandoned) and then destroys the
/// context if it is still alive. Must run on `eventLoopQueue`.
private func failPendingAndDestroyContext(with error: any Error) {
    failAllPendingOperations(with: error)
    if let ctx = context { Self.destroyContext(ctx); context = nil }
}
```

**Load-bearing ordering inside the helper (review condition):** `failAllPendingOperations` MUST
stay immediately before the destroy. Abandoning first is what makes every callback libsmb2 fires
from `smb2_destroy_context` take `generic_handler`'s `isAbandoned` early return, which is in turn
what makes the D-2 `[weak self]` capture unobservable (see D-2). Do not "simplify" the helper by
destroying first and failing afterwards.

**Consequence for `shutdown()` (accepted):** calling the helper at the end moves `shutdown()`'s
fd-path disconnect PDU + `smb2_service(POLLOUT)` to *before* `failAllPendingOperations`, where
today it runs after. This is safe because at `deinit` there can be no *non*-abandoned pending
operation: `async_await` / `async_await_pdu` / `connectWithBridge` are instance methods, so a
suspended caller's frame holds a strong `self` and `deinit` cannot have started; every `CBData`
still in `pendingOperations` at `deinit` was already abandoned by a cancel or timeout. Record that
invariant in the code comment on the helper — a future path that leaves a live, non-abandoned
operation while the client deallocates would break it.

`deinit`'s existing `guard context != nil` makes disconnect-then-release a single destroy.
*Alternative — call `shutdown()` from `disconnect()` directly:* rejected; the error code differs
(`ENOTCONN` is the documented disconnect error, `ECANCELED` the deinit one, and
`testShortTimeoutFiresOnLargeWrite` / `disconnect-fix` spec depend on them) and the seam PDU
emission belongs to `disconnect()` only (Non-Goal). *Alternative — drain PDUs without destroying
(issue Option B):* libsmb2 has no per-PDU cancel; collapses into D-1. *Alternative — docs only
(issue Option C):* does not reclaim anything and leaves the retain cycle.

**D-2: `dataHandler` wrappers capture the client weakly.**
`cb.dataHandler = { [weak self] ptr in guard let self else { return } ... }` in both
`async_await` and `async_await_pdu`. This structurally removes the
`PDU → CBData → SMB2Client → context → PDU` cycle for every operation, not just those caught by
`disconnect()`. **Why the weak reference is never observed nil (corrected during review):** the "generic_handler
always runs inside a method on a live `self`" argument does NOT hold for the `deinit` path — Swift
zeroes weak references once deallocation begins, so a `[weak self]` read inside
`deinit -> shutdown() -> smb2_destroy_context -> generic_handler` yields `nil`. The real invariant
is an ordering one: `dataHandler` is invoked ONLY on `generic_handler`'s non-abandoned branch
(`Context.swift:866-882`), and every teardown that can destroy the context from `deinit` runs
`failAllPendingOperations` first (D-1 helper), so those callbacks early-return before reaching
`dataHandler`. On the `disconnect()` and `smb2_service`-error paths `self` is a live strong
reference held by the enclosing `eventLoopQueue.async` block, so the handler runs normally. The
`guard let self else { return }` is therefore belt-and-braces, not a live code path: if it ever
did fire, `resultData` would stay nil and the caller — already resumed — is unaffected.
*Alternative — nil `dataHandler` / `cleanup` in `failAllPendingOperations`, `onCancel` and the
timeout timer:* rejected; three sites to keep in sync versus one root cause, and a future fourth
abandon path would silently reintroduce the cycle. D-3 still clears them at the single point where
libsmb2 hands the object back.

**D-3: `generic_handler`'s abandoned branch clears `cleanup` and `dataHandler`.**
Before `return` on `isAbandoned`, set `cbdata.cleanup = nil; cbdata.dataHandler = nil`. This is
the last time anyone touches an abandoned `CBData`; clearing here breaks the seam connect path's
`cleanup → cb` self-retain and releases whatever the caller's `dataHandler` captured (buffers,
handles) once libsmb2 has balanced the retain.
*Alternative — `[weak cb]` in the connect `cleanup` closure:* rejected; it still leaves caller
captures in `dataHandler` alive and only fixes one site.

**D-4: Contract — `disconnect()` is terminal for the instance.**
Doc comment on `disconnect()`: after it returns the client has no context; every subsequent
operation throws `ENOTCONN` immediately; construct a fresh client to reconnect. This matches the
existing `SMB2Manager.smbClient` documentation and `SMB2Manager.connect(shareName:)`, which
already builds a new client on every `connectShare` (reuse audit in proposal.md — Impact).
**Reuse-audit gap found in review:** `SMB2Manager.with(shareName:encrypted:completionHandler:)`
(`AMSMB2.swift:1683-1701`, used by the two `listShares` entry points at `:482` and `:512`) calls
`connect(shareName:)` — which does `setClient(client)` — then `await client.disconnect()` WITHOUT
a following `setClient(nil)`. So after any `listShares()` the manager's `client` already points at
a disconnected instance, and after this change it points at a context-less one. Verified safe and
in fact improved: `needsReconnect` (`:375`) returns true because `fileDescriptor` falls back to
`-1` once `context` is nil (`Context.swift:556-564`), and `smbClient` (`:39`) throws `ENOTCONN`
because `isConnected` (`Context.swift:543`) is false. Today on the fd path `smb2_get_fd` still
returns the live socket after `disconnect()`, so `needsReconnect` relied on the `share != name`
check and the `echo()` workaround; the change makes that path deterministic. No code change
required — but add an assertion for it (see D-6 guards).
Observable improvement to record in the spec: stale-`SMB2FileHandle` operations now fail fast
instead of queuing into a transport-less context and hanging for `timeout` → `ETIMEDOUT`.
`SMB2FileHandle.deinit`'s `fireAndForget` close already no-ops on `context == nil`.

**D-5: Observability for tests — a live-instance counter on `CBData`.**
Add an internal `CBData.liveCount` (lock-guarded `Int`, incremented in `init`, decremented in
`deinit`; `@testable`-visible, no `#if DEBUG`). This gives the issue's "CBData-deinit sentinel"
as a single mechanism every test can assert against (`liveCount` returns to its pre-test
baseline *after `disconnect()` returns and before the client is dropped*), and is the only way
to observe the connect-path `CBData` (D-3), which has no caller-supplied closure to hang a
sentinel on. Cost: one uncontended lock acquire per operation, negligible next to a network round
trip. *Why not `#if DEBUG`:* state the reason in the implementation comment — `swift test`,
`make integrationtest` and `make linuxtest` all build debug, so `#if DEBUG` would work, but an
unconditional counter keeps release and debug binaries behaviourally identical (no
configuration-dependent `CBData` layout or lock ordering) and matches the existing unconditional
`pendingSeamOperationCount` / `hasInstalledSeamBridge` accessors. Precedent: `pendingSeamOperationCount`, `hasInstalledSeamBridge`,
`consumeInboundReadySignal` are existing internal test accessors.
*Alternative — sentinel object captured by the test's `dataHandler`:* works only for
`async_await`, not the connect path; rejected as the sole mechanism.
**Timer caveat found during implementation:** the per-operation timeout timers
(`eventLoopQueue.asyncAfter` in `async_await`, `async_await_pdu` and `connectWithBridge`) capture
`cb` **strongly**, so with `timeout > 0` the abandoned `CBData` — by then an empty shell, its
closures cleared by D-3 — stays allocated until that timer fires (bounded by `timeout`, not a
leak). The unit tests that assert `liveCount == baseline` immediately after `disconnect()`
therefore construct the client with `timeout: 0` (no timer armed); the integration test sets a
short manager timeout and polls for the baseline. Changing those timers to `[weak cb]` (with a
`guard let cb` so a recycled `ObjectIdentifier` can never evict a different pending operation)
would make the count return at `disconnect()` for every timeout value; deliberately left out of
this change as unrequested scope — flagged as a follow-up.

**D-6: Verification strategy (TDD; each test MUST be RED on current code).**
- *Unit, all platforms, no server — `async_await` path:* fresh `SMB2Client(timeout: 30)`;
  from a `Task` call `client.async_await { smb2_echo_async($0, SMB2Client.generic_handler, $1) }`
  directly (bypassing `echo()`'s `isConnected` gate; `smb2_echo_async` has no session/transport
  precondition — `libsmb2.c:2729`, it just `smb2_queue_pdu`s). With no bridge / socket monitor
  the PDU sits in `outqueue`. **Verified during review:** `smb2_echo_async` (`libsmb2.c:2729`)
  -> `smb2_cmd_echo_async` (`smb2-cmd-echo.c:84`) -> `smb2_allocate_pdu` (`pdu.c:86`) ->
  `smb2_queue_pdu` (`pdu.c:663`) -> `smb2_add_to_outqueue` has no session, transport, credit or
  `ext_connected` precondition, so the PDU does queue on a never-connected context — task 2.1 is
  viable and the 2.2 fallback is a safety net, not the expected path. Two mechanics the test must
  get right: the test file needs `import SMB2` (the `smb2_*` symbols are not re-exported through
  `@testable import AMSMB2`), and `pendingSeamOperationCount` sits inside `#if canImport(Network)`
  (`Context.swift:566-581`) — either widen that accessor to all platforms or gate the
  pending-count wait so the test still compiles and runs on Linux.
  Wait until the pending count is 1, then:
  `await client.disconnect()` → the task throws `ENOTCONN`; assert `liveCount == baseline`
  (RED today: the callback never fires); drop the last strong reference and assert a `weak`
  reference to the client is nil (RED today: cycle). If `smb2_queue_pdu` turns out to refuse a
  PDU on a never-connected context, fall back to the seam variant below for both assertions and
  record it in tasks.md.
- *Unit, Apple seam — connect path:* `connectWithBridge` with a never-reply transport (sends
  dropped, `receive()` parks — `GatedConnectTransport` with the gate opened up front, or
  `MockTransport(sendsAreDropped: true)`), so NEGOTIATE is pending in libsmb2's queues. Call
  `disconnect()` concurrently: the connect throws `ENOTCONN`, `pendingSeamOperationCount == 0`,
  `hasInstalledSeamBridge == false`, `liveCount == baseline` (RED today for the self-retained
  connect `CBData`), then weak client nil after release. Also assert a `weak var` on the
  `TransportBridge` is nil after `disconnect()` — RED today, because only
  `smb2_destroy_context -> ext_close` balances the `ext.userdata` retain (see Context).
- *Unit — teardown idempotence:* after `disconnect()`, `client.fileDescriptor == -1`,
  `isConnected == false`, a subsequent `async_await` throws `ENOTCONN` immediately (assert
  elapsed « `timeout`), a second `disconnect()` returns, and releasing the client does not crash
  (single destroy). Run under `--sanitize=address` locally; record if not possible.
- *Integration (`SMBIntegrationTestCase`, skipped without `SMB_SERVER`):* in
  `SMB2DisconnectTimeoutTests`, start a large read, capture `weak var weakClient = try
  smb.smbClient` while in flight, `disconnectShare(gracefully: false)`, await the read's
  failure, then assert `weakClient == nil` (allowing a brief yield for the operation closure to
  release its capture) and `liveCount == baseline`. This is the original pool-teardown scenario
  and exercises the fd path on Linux (`make linuxtest`) and the seam path on macOS.
- *Existing tests as guards:* `SMB2CBDataLifetimeTests` (destroy-at-deinit still balances
  exactly once), `SMB2DisconnectTimeoutTests.testOperationsFailAfterDisconnect` (post-disconnect
  errors are `POSIXError`), `testReconnectAfterDisconnectFullRoundTrip` (Manager reconnect
  unaffected), `GlobalContextListRaceTests` (destroy under `globalContextLock`).

## Risks / Trade-offs

- [Late callback from the destroy sweep resumes an already-resumed continuation] → Ordering in
  D-1 step 3 before step 4 (`isAbandoned` set first); identical to what `shutdown()` does today.
- [`flushOutboundForSeam` / `smb2_service(POLLOUT)` destroys the context on error before the
  tail] → `if let` guard in the shared tail; `teardownSeam()` and `failAllPendingOperations` are
  already idempotent.
- [Something queued behind `disconnect()` on `eventLoopQueue` touches a nil context]
  → `fireAndForget` guards on `context`, `withContext` throws via `unwrap()`, `async_await` /
  `async_await_pdu` guard and release before queuing — all pre-existing paths for the
  service-error case that already nils the context.
- [`smb2_echo_async` cannot be queued on a never-connected context in the unit test] → fall back
  to the seam connect variant (known to queue NEGOTIATE); the `async_await` `[weak self]` change
  is then covered by the integration test plus the review checklist.
- [Weak-captured client is nil inside `dataHandler`] → argued unreachable (D-2); the guard makes
  it a silent no-op rather than a crash, and `generic_handler` still balances the retain.
- [`liveCount` lock on the hot path] → one uncontended `NSLock` per operation; measured against a
  network round trip this is noise. Tests must compare against a baseline read at test start,
  not `0`, because other tests in the same process may hold live instances.
- [Behaviour change for consumers holding a stale `SMB2FileHandle`] → fail-fast `ENOTCONN`
  instead of a `timeout`-long hang; recorded in the `disconnect-fix` delta spec as intended.
- [A consumer-held `SMB2FileHandle` / `SMB2Directory` released *after* `disconnect()` strands its
  C handle] → `SMB2FileHandle.deinit` / `close()` (`FileHandle.swift:132-163`) and
  `SMB2Directory.deinit` (`Directory.swift:34-42`) route through `fireAndForget`, which guards on
  a live context; with the context destroyed the `smb2_close_async` / `smb2_closedir` never runs
  and the `struct smb2fh` / `struct smb2dir` allocation is stranded. Accepted: tens of bytes per
  handle, and only for handles a *consumer* holds across the disconnect (handles created inside
  `SMB2Manager` operations are released first). Both types hold a strong `client`, so this can
  never strand the client itself. Do not "fix" it by deferring the destroy — that reinstates the
  leak this change removes.
- [`flushOutboundForSeam` fires pending callbacks before they are abandoned] → the D-1 ordering
  deliberately keeps `failAllPendingOperations` *after* the seam disconnect-PDU flush, matching
  the archived `disconnect-fix` requirement "After sending the disconnect PDU, `disconnect()` MUST
  fail all pending in-flight operations". If `smb2_service(POLLOUT)` errors inside that flush it
  destroys the context (`Context.swift:1738`) while the pending `CBData` are still live, so those
  callers are resumed by `generic_handler` with the SHUTDOWN status instead of `ENOTCONN`. This is
  pre-existing behaviour of that error path and is left alone; hoisting `failAllPendingOperations`
  ahead of the flush would be strictly safer but contradicts that archived requirement and would
  need its own MODIFIED delta.
- [Upstream libsmb2: `smb2_destroy_context` can double-fire a callback] → `init.c:331-338` fires
  and frees `smb2->pdu`, then the `waitqueue` drain (`:339-351`) can fire and free the *same* PDU,
  because `smb2->pdu = NULL` is assigned only inside that loop, after the earlier free. Reachable
  only when `smb2_service` returned from `socket.c:558-566` ("compound reply received out of
  order") with `smb2->pdu` set and still linked — i.e. only on the existing `smb2_service`-error
  destroy paths, never on the clean `disconnect()` / `deinit` destroy where `smb2->pdu` is NULL.
  Pre-existing and unchanged here; recorded so it is not misdiagnosed as a regression of the
  `takeRetainedValue()` contract.

## Migration Plan

Source-only, no API change. Ship as the next `5.99.x` pre-release; rollback = revert the commit.
Consumers that relied on `SMB2Manager.smbClient` staying usable after `disconnectShare` were
already outside the documented contract.
