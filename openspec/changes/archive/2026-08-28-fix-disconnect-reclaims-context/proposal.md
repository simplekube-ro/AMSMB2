## Why

GitHub issue #49 reports that `SMB2Client.disconnect()` tears down the transport and fails pending
operations but never destroys the `smb2_context`, so the `CBData` of any operation still in flight
at disconnect time is not reclaimed until `deinit`. Reading the current code shows the problem is
worse than "bounded until deinit": the `cb.dataHandler` wrapper in `async_await` /
`async_await_pdu` (`Context.swift:917`, `:1022`) captures `self` **strongly**, forming the cycle
`smb2_context.waitqueue → pdu.cb_data (+1) → CBData.dataHandler → SMB2Client → context`.
After `disconnect()` closes the bridge/socket source, `smb2_service` never runs again, the
callback never fires, the `+1` is never balanced, and `SMB2Client.deinit` (the only place that
calls `smb2_destroy_context`) is unreachable. A non-graceful `disconnectShare()` with a
never-replying read in flight therefore leaks the entire client — context, event-loop queue,
`CBData`, abandoned `RawBuffer` — permanently, and the consumer cannot release it because
`SMB2Manager` already dropped its reference. This is the exact pool-teardown scenario behind the
crash fixed in PR #48 (`fix-cbdata-cancel-race-uaf`), whose design doc recorded this as an open
question.

## What Changes

- `SMB2Client.disconnect()` becomes **terminal**: after the best-effort disconnect PDU + flush and
  `failAllPendingOperations(.ENOTCONN)`, it destroys the `smb2_context` and nils `self.context`,
  exactly mirroring `shutdown()`. `smb2_destroy_context`'s teardown sweep fires every pending
  PDU's callback, so each `CBData` retain is balanced at disconnect time rather than deferred.
  The two near-duplicate teardown sequences (`shutdown()` / `disconnect()`) are unified into one
  shared routine parameterised by the failure error (`ECANCELED` at `deinit`, `ENOTCONN` at
  disconnect). Applies to both the Apple seam path and the legacy (`#if !canImport(Network)`)
  fd path.
- The `CBData.dataHandler` wrapper closures in `async_await` and `async_await_pdu` capture the
  client **weakly**, so a pending or abandoned operation can never pin its `SMB2Client` — a
  cancelled/timed-out operation on a never-replying share no longer keeps the client alive until
  some later teardown.
- `generic_handler`'s `isAbandoned` early-return also clears `cleanup` and `dataHandler`, so an
  abandoned `CBData` whose `cleanup` closure captures the `CBData` itself (the seam connect path,
  `Context.swift:1598`) does not self-retain after libsmb2 has balanced the external retain.
- The `disconnect()`-then-reuse contract is decided and documented: a disconnected `SMB2Client`
  has no context and cannot be reconnected; construct a fresh client (which is what
  `SMB2Manager.connect(shareName:)` already does on every `connectShare`).
- Observable side effect (documented, not a regression): an operation issued on a stale
  `SMB2FileHandle` after `disconnect()` now fails immediately with `ENOTCONN` (from
  `async_await`'s `context == nil` guard) instead of queuing a PDU into a transport-less context
  and hanging for the operation timeout before `ETIMEDOUT`.
- Regression coverage: deterministic unit tests (no server) proving the `CBData` is released at
  `disconnect()` and that the client deinitialises afterwards; an integration test under
  `SMBIntegrationTestCase` for non-graceful disconnect mid-read that asserts the client is
  deallocated.

No public API signature changes. `SMB2Manager.disconnectShare` behaviour for callers is unchanged
(pending operations still receive `ENOTCONN`; reconnect still works because it always builds a
fresh client).

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `disconnect-fix`: `disconnect()` now additionally destroys the `smb2_context` after failing
  pending operations, is terminal for the client instance, and makes post-disconnect operations
  fail fast with `ENOTCONN`.
- `operation-cancellation-lifetime`: adds the requirements that a pending/abandoned `CBData` MUST
  NOT strongly retain its `SMB2Client` (no retain cycle through libsmb2's queues), that an
  abandoned `CBData` releases its closures when libsmb2 balances the retain, and that
  `disconnect()` reclaims every pending `CBData` at disconnect time.

## Impact

- **Code:** `AMSMB2/Context.swift` only — `disconnect()`, `shutdown()`, `deinit` guard (already
  idempotent via `context != nil`), the two `cb.dataHandler` wrappers, `generic_handler`'s
  abandoned branch, and a doc comment on `disconnect()`. No signature changes.
- **Reuse audit (done during exploration):** no code path reconnects the same `SMB2Client` after
  `disconnect()`. `SMB2Manager.connect(shareName:)` constructs a fresh client
  (`AMSMB2.swift:1621`); `needsReconnect` compares `fileDescriptor == -1`, which on the seam is
  always true, so Apple rebuilds the client on every `connectShare` regardless. `SMB2Client.init`
  and `disconnect()` are internal, so consumers cannot call `disconnect()` directly; they reach
  the client only via `smbClient` (already documented as invalidated by disconnect) or a held
  `SMB2FileHandle`. `testTeardownSeamResetsInboundReadyDebounce` exercises `teardownSeam()`
  only, never the context, and is unaffected.
- **Tests:** new deterministic unit tests in `AMSMB2Tests/SMB2CBDataLifetimeTests.swift` (or a
  sibling file); new integration test in `AMSMB2Tests/SMB2DisconnectTimeoutTests.swift`.
  Existing `testOperationsFailAfterDisconnect` asserts only `POSIXError`, compatible with the
  fail-fast `ENOTCONN`.
- **Platforms:** all. The seam arm is `canImport(Network)`; the fd arm is Linux.
- **Dependencies:** none. Relies on the already-verified libsmb2 `smb2_destroy_context` sweep
  (`Dependencies/libsmb2/lib/init.c:313-380`): `transport->close` first (the seam `ext.close`
  trampoline is nil-safe and once-only, `TransportBridge.swift:231`), then every
  `outqueue`/`pdu`/`waitqueue` callback with `SMB2_STATUS_SHUTDOWN`, then `connect_cb`.
- **Out of scope:** the intentional one-`RawBuffer`-per-cancelled-read `bufferPool.abandon`
  leak (accepted in `fix-cbdata-cancel-race-uaf`); sending the seam disconnect PDU from
  `deinit`/`shutdown()` (unrelated behaviour change, kept surgical).
- **Risk:** low and localised. The destroy sequence is the one `shutdown()` already runs at every
  `deinit`, already covered by `SMB2CBDataLifetimeTests`.

## Review

**Reviewer:** project-architect (mandatory `/opsx:propose` review gate)
**Date:** 2026-08-28

APPROVED WITH CONDITIONS

### Verdict summary

The central claim is **confirmed against the code**, the approach (D-1 … D-4) is the right one,
and the delta specs are well-formed. Approval is conditional on six corrections, all of which are
within the approved approach; five of them I have already applied to `design.md`, `tasks.md` and
`specs/disconnect-fix/spec.md` (see *Artifacts edited during review* below). The remaining work
is for the implementing agent to honour the conditions in §Conditions.

### Findings

1. **The retain cycle is real, and it is a permanent leak — claim CONFIRMED.**
   `AMSMB2/Context.swift:916-922` and `:1024-1030` both set
   `cb.dataHandler = { ptr in ... dataHandler(self, ptr) ... }`, capturing `self` **strongly**
   (the `cb.cleanup` closures at `:958` and `:1066` are already `[weak self]`, so the wrapper is
   the only strong edge). Once the PDU is queued, libsmb2 owns a `+1` on `CBData`
   (`:939`, `:1047`) that only `generic_handler` balances (`:867`). `disconnect()` (`:639-673`)
   never destroys the context, and after `teardownSeam()` / `stopSocketMonitoring()` nothing calls
   `smb2_service` again, so the callback never fires. `SMB2Client.deinit` (`:208-215`) is the only
   caller of `shutdown()` → `smb2_destroy_context`, and it is unreachable while the C side holds a
   strong reference to the client. The issue's "bounded until `deinit`" framing is too generous —
   this is unbounded. The proposal's Why is accurate.

2. **The leak is bigger than `CBData`: the `TransportBridge` is stranded too — NOT in the
   artifacts (now added to design.md — Context).**
   `TransportBridge.makeExternalTransport()` (`AMSMB2/TransportBridge.swift:200-204`) hands
   libsmb2 `Unmanaged.passRetained(self)` via `ext.userdata`. The **only** consumer of that `+1`
   is the C `ext.close` trampoline (`TransportBridge.swift:231-241`), which libsmb2 invokes from
   `smb2_destroy_context`'s `transport->close` call (`Dependencies/libsmb2/lib/init.c:319-321`).
   `teardownSeam()` (`Context.swift:1795-1809`) nils `transportBridge` and calls the *Swift*
   `bridge.close()` — it never reaches `ext_close`. So today `disconnect()` also strands the
   bridge and its `TCPTransportApple` / NIO channel. D-1 fixes this for free and yields a second
   cheap RED assertion (weak bridge nil after `disconnect()`), now required in task 2.2.

3. **D-1 ordering safety — CONFIRMED, with one correction to the `shutdown()` reorder.**
   `smb2_destroy_context` (`init.c:313-382`) does `transport->close` → every `outqueue` / `pdu` /
   `waitqueue` callback with `SMB2_STATUS_SHUTDOWN` → `connect_cb`, so the destroy sweep does
   balance every pending `CBData`. The `ext.close` trampoline is once-only (C-side clears
   `ext.close` before invoking, `transport-external.c:275-297`), so destroying after
   `teardownSeam()` already closed the bridge is safe and is exactly what balances the bridge
   retain. `flushOutboundForSeam` can itself destroy the context (`Context.swift:1738-1743`), so
   the `if let` guard in the tail is required — as stated. **Correction:** extracting the tail as
   `failAll → guarded destroy` moves `shutdown()`'s fd-path disconnect PDU +
   `smb2_service(POLLOUT)` (`:196-201`) to *before* `failAllPendingOperations`, a reorder the
   design did not acknowledge. It is safe, but only because a suspended `async_await` /
   `async_await_pdu` / `connectWithBridge` caller's frame retains `self`, so `deinit` cannot run
   while a non-abandoned operation is pending. That invariant is now written into design.md D-1
   and required as a code comment (task 3.3).

4. **D-2 `[weak self]` is correct, but its stated justification is WRONG — corrected in
   design.md.** The design argued "`self` is never nil … `generic_handler` fires only inside
   `smb2_service` / `smb2_destroy_context`, both invoked from a method executing on a live
   `self`". That does not hold for `deinit → shutdown() → smb2_destroy_context → generic_handler`:
   Swift zeroes weak references once deallocation begins, so a `[weak self]` read there yields
   `nil`. The correct invariant is an *ordering* one: `dataHandler` runs only on
   `generic_handler`'s non-abandoned branch (`Context.swift:866-882`), and every teardown that can
   destroy the context from `deinit` runs `failAllPendingOperations` first — so those callbacks
   early-return before touching `dataHandler`. No `dataHandler` in the codebase needs the client
   after the client could be gone: the only consumers are the caller-supplied
   `ContextHandler<DataType>` parsers, which run on a live client during normal servicing. This
   makes the D-1 fail-before-destroy ordering *load-bearing for D-2*, not merely nice to have.

5. **D-3 is justified and the site is confirmed.** `connectWithBridge`'s
   `cb.cleanup` (`Context.swift:1601-1607`) captures `cb` strongly (it reads `cb.result`), and
   `generic_handler` clears `cleanup` only on the non-abandoned branch (`:876`). So an abandoned
   connect `CBData` self-retains forever after libsmb2 balances its retain — a genuine (small)
   permanent leak, and the only one `liveCount` can observe. No path relies on an abandoned
   `CBData`'s `cleanup` running later: `failAllPendingOperations` (`:393-405`), the `onCancel`
   blocks (`:983-993`, `:1653-1666`) and the timeout timers (`:963-972`, `:1616-1629`) all remove
   the entry from `pendingOperations` themselves before/without invoking `cleanup`. D-3 is safe.

6. **D-5 `liveCount` — acceptable, with the rationale to be recorded.** There is no cleaner way to
   observe the connect-path `CBData` release: it has no caller-supplied `dataHandler` to hang a
   sentinel on and the object never escapes `connectWithBridge`. Precedent exists
   (`pendingSeamOperationCount`, `hasInstalledSeamBridge`, `Context.swift:566-581`). One
   uncontended `NSLock` per operation is noise next to a round trip. The design asserted "no
   `#if DEBUG`" without a reason; I added the rationale (identical debug/release behaviour, no
   configuration-dependent `CBData` layout) and made recording it a task (1.1). Baseline-relative
   assertions are mandatory — a process-global counter is otherwise flaky.

7. **D-6 task 2.1 IS viable — verified in the vendored libsmb2.** `smb2_echo_async`
   (`Dependencies/libsmb2/lib/libsmb2.c:2729-2756`) → `smb2_cmd_echo_async`
   (`smb2-cmd-echo.c:84-105`) → `smb2_allocate_pdu` (`pdu.c:86`) → `smb2_queue_pdu`
   (`pdu.c:663-714`) → `smb2_add_to_outqueue` has **no** session, transport, credit or
   `ext_connected` precondition. The PDU queues on a never-connected context and
   `activateServicingAfterOperation` (`Context.swift:377-386`) no-ops (nil bridge / nil monitor),
   so it sits in `outqueue` as designed. The 2.2 fallback is a safety net, not the expected path.
   **Two mechanical blockers found:** (a) `pendingSeamOperationCount` is declared inside
   `#if canImport(Network)` (`Context.swift:566-581`), so the "all platforms" test cannot read it
   on Linux; (b) `SMB2CBDataLifetimeTests.swift` is itself wholly inside `#if canImport(Network)`,
   so the platform-neutral test needs a new sibling file, and that file needs `import SMB2` for
   the `smb2_*` symbols. Both are now tasks (1.2, 2.1).

8. **Reuse audit — the proposal's conclusion holds, but it MISSED one site (now added to
   design.md).** `SMB2Manager.with(shareName:encrypted:completionHandler:)`
   (`AMSMB2/AMSMB2.swift:1683-1701`, used by both `listShares` entry points at `:482` and `:512`)
   calls `connect(shareName:)` — which does `setClient(client)` (`:1636`) — then
   `await client.disconnect()` (`:1692`, `:1695`) **without** a following `setClient(nil)`. So the
   manager's `client` already points at a disconnected instance after any `listShares()`. Verified
   safe and in fact improved by this change: `needsReconnect` (`:375-379`) returns true because
   `fileDescriptor` falls back to `-1` once `context` is nil (`Context.swift:556-564`), and
   `smbClient` (`:39-50`) throws `ENOTCONN` because `isConnected` (`Context.swift:543-554`) is
   false. Today on the fd path `smb2_get_fd` still returns a live socket after `disconnect()`, so
   that path relied on the `share != name` check plus the `echo()` workaround; the change makes it
   deterministic. Nothing reconnects a disconnected `SMB2Client` anywhere
   (`SMB2SeamIntegrationTests.swift:54` is a teardown block). A regression guard is now task 4.4a.

9. **New (accepted) side effect the artifacts missed: consumer-held handles strand their C
   allocation.** `SMB2FileHandle.deinit` / `close()` (`AMSMB2/FileHandle.swift:132-163`) and
   `SMB2Directory.deinit` (`AMSMB2/Directory.swift:34-42`) route through `fireAndForget`
   (`Context.swift:231-236`), which guards on a live context. With the context destroyed at
   `disconnect()`, the `smb2_close_async` / `smb2_closedir` never runs and the `struct smb2fh` /
   `struct smb2dir` is stranded (today the queued close PDU is freed by the destroy sweep at
   `deinit`). Tens of bytes, only for handles a *consumer* holds across the disconnect; both types
   hold a strong `client`, so it can never strand the client itself. Recorded in design.md Risks
   as accepted — explicitly **not** to be "fixed" by deferring the destroy.

10. **Pre-existing hazards surfaced, deliberately out of scope (recorded in design.md Risks so
    they are not misdiagnosed later).** (a) `flushOutboundForSeam` runs before
    `failAllPendingOperations` in `disconnect()`; if `smb2_service(POLLOUT)` errors there it
    destroys the context (`Context.swift:1738`) with the pending `CBData` still live, so those
    callers are resumed with the SHUTDOWN status rather than `ENOTCONN`. Hoisting the fail step
    ahead of the flush would be strictly safer but contradicts the archived `disconnect-fix`
    requirement "After sending the disconnect PDU, `disconnect()` MUST fail all pending in-flight
    operations" and needs its own MODIFIED delta — correctly left alone here. (b) Upstream
    `smb2_destroy_context` can double-fire a callback: `init.c:331-338` fires and frees
    `smb2->pdu`, then the `waitqueue` drain (`:339-351`) can fire and free the *same* PDU, because
    `smb2->pdu = NULL` is assigned only inside that loop after the earlier free. Reachable only
    when `smb2_service` returned from `socket.c:558-566` ("compound reply received out of order")
    with `smb2->pdu` set and still linked — i.e. only on the existing `smb2_service`-error destroy
    paths, never on the clean `disconnect()` / `deinit` destroy where `smb2->pdu` is NULL.
    Exposure is unchanged by this proposal.

11. **Spec quality — PASS.** Both deltas use `## ADDED Requirements` with no partial-content
    `MODIFIED` blocks; requirement names do not collide with the existing
    `openspec/specs/disconnect-fix/spec.md` (3 requirements) or
    `openspec/specs/operation-cancellation-lifetime/spec.md` (3 requirements); every requirement
    carries WHEN/THEN scenarios that map to a named task; no requirement is invented beyond what
    the change delivers. `openspec validate fix-disconnect-reclaims-context --strict` passes after
    my edits. I added one scenario ("External transport handle is released at disconnect") to
    `specs/disconnect-fix/spec.md` to cover finding #2.

12. **Quality gates.** No public API signature changes; `SMB2Client.init` / `disconnect()` stay
    internal. No new dependency. Both platform arms covered (seam `#if canImport(Network)`, fd
    Linux). Thread safety preserved — every new statement stays on `eventLoopQueue`, and
    `Self.destroyContext` keeps taking `globalContextLock` (`Context.swift:169-174`), so
    `GlobalContextListRaceTests` semantics are unchanged. Post-destroy queued work is already
    nil-context-safe: `handleSocketEvent` (`:327`), `flushOutboundForSeam`'s re-arm (`:1748-1751`),
    `scheduleSeamTimeout`'s work item (`:1783`), `fireAndForget` (`:232`), `withContext`'s
    `unwrap()` (`:224`) and both `async_await` setup guards (`:940`, `:1048`) all guard on
    `context`. `NSSecureCoding` / `Codable` are unaffected — neither encodes `client`.

### Conditions

1. The shared teardown helper MUST be exactly `failAllPendingOperations(with:)` immediately
   followed by the `if let`-guarded `destroyContext` + `context = nil`, with nothing between them,
   and MUST carry the code comment explaining that fail-before-destroy is what makes D-2's
   `[weak self]` unobservable during `deinit` (finding #3/#4, task 3.3).
2. Task 1.2 must be resolved before 2.1/2.3 are written: either widen the pending-count accessor
   out of `#if canImport(Network)` or gate the assertions, so the tests compile and run under
   `make linuxtest` (finding #7).
3. Task 2.2 must additionally assert a `weak` `TransportBridge` reference is nil after
   `disconnect()` (finding #2). This is the RED assertion for the stranded bridge retain.
4. Every `liveCount` assertion compares against a baseline captured at test start, never `0`.
5. Task 4.4a (the `listShares()`-then-`connectShare()` regression guard) is required, not
   optional (finding #8).
6. Run the new unit tests under `swift test --disable-sandbox --sanitize=address` (task 4.1) —
   the destroy sweep now runs on every `disconnect()`, which is the exact code path
   `fix-cbdata-cancel-race-uaf` guarded. If ASan is unavailable, record that in tasks.md rather
   than silently skipping.

### Artifacts edited during review

- `design.md` — corrected line references (`Context.swift` `:350/:1711/:1739/:867/:917/:1022/:1598`
  → `:349/:1710/:1738/:866/:916/:1024/:1601`); added the `TransportBridge` `ext.userdata` retain
  finding to Context; added the reuse-audit gap (`AMSMB2.swift:1683-1701` / `listShares`) to D-4;
  added the concrete helper shape, its load-bearing ordering, and the `shutdown()` reorder
  justification to D-1; replaced D-2's incorrect "self is never nil" argument with the ordering
  invariant; added the `#if DEBUG` rationale to D-5; added the verified libsmb2 call chain and the
  two mechanical blockers to D-6; added four risks (stranded `smb2fh`/`smb2dir`, the
  flush-error window, the upstream `smb2_destroy_context` double-fire, and the weak-bridge
  observable).
- `tasks.md` — new task 1.2 (platform-neutral pending count) and 4.4a (`listShares` reuse guard);
  strengthened 1.1, 2.1, 2.2 and 3.3 with the conditions above and the extra green-tests list.
- `specs/disconnect-fix/spec.md` — added the scenario "External transport handle is released at
  disconnect".
- No Swift source was modified.
