## Context

`SMB2Client` bridges Swift `async`/`await` to libsmb2's callback-based async API. Each operation
allocates a `CBData` (`Context.swift:789`) and hands it to libsmb2 as an opaque `void *cbdata`
via `Unmanaged.passRetained(cb).toOpaque()` (a `+1` the C side now conceptually owns). The single
balancing release is `Unmanaged<CBData>.fromOpaque(...).takeRetainedValue()` inside the shared
`generic_handler` (`Context.swift:861`).

The ownership invariant the code depends on (and that libsmb2 enforces): **once a PDU is queued,
libsmb2 will call that PDU's callback exactly once** — either on the network reply (`read_cb` →
`generic_handler`) or during `smb2_destroy_context`, which walks `outqueue`/`pdu`/`waitqueue` and
fires every pending callback with `SMB2_STATUS_SHUTDOWN` before freeing (verified in
`Dependencies/libsmb2/lib/init.c:323-351`). Therefore, after a PDU is queued, the `+1` must be
released **only** by `generic_handler`.

The existing cancellation/timeout paths already respect this: `onCancel` (`Context.swift:971-983`),
the timeout timer (`:954-964`), and `failAllPendingOperations` (`:393-403`) set `isAbandoned`,
resume the continuation, and remove bookkeeping — but **do not** release the retain. The same
principle is applied to read buffers (`bufferPool.abandon`, `Context.swift:70`), which are
intentionally leaked on cancel because "the C callback still owns the pointer."

Three branches violate the invariant. When a Swift `Task` is cancelled in the narrow window
between the setup block calling the libsmb2 async function (which queues the PDU) and the block
storing the continuation, the setup block detects `cb.isAbandoned == true` and calls
`Unmanaged<CBData>.fromOpaque(cbPtr).release()`:
- `async_await` line 943 (covers reads/writes/stat/etc. — the captured crash)
- `async_await_pdu` line 1043
- `connectWithBridge` line 1308 (Apple seam connect)

For `isAbandoned` to be true here, `onCancel` ran on `eventLoopQueue` before the setup block —
i.e. cancellation arrived first under concurrent load. The PDU is already queued, so this release
is a *second* balance against the one `generic_handler` will perform later → use-after-free when
the slow reply arrives on a live context, or at `smb2_destroy_context`.

## Goals / Non-Goals

**Goals:**
- Eliminate the `CBData` use-after-free triggered by Task cancellation racing operation setup.
- Make the post-queue cancellation branch behave identically to the already-correct `onCancel`
  path: abandon without releasing; let `generic_handler` perform the single balancing release.
- Add a deterministic regression test for the retain-balance invariant and an opt-in stress
  harness for sanitizer validation.

**Non-Goals:**
- Introducing a libsmb2 per-PDU client cancellation primitive. libsmb2 exposes none — only
  `smb2_destroy_context` (abort all) and `smb2_set_timeout`. Not in scope.
- Reworking pool/lease lifetime in the consuming app (separate repo). The fix lives entirely in
  AMSMB2 and makes a recycled/abandoned client's in-flight reads safe regardless of pool timing.
- Changing the `disconnect()` semantics (it leaves the context alive until `deinit`; pending PDUs
  are balanced at `smb2_destroy_context`). That is a bounded leak window, not a crash, and is
  out of scope; see Open Questions.

## Decisions

**D-1: Remove the premature `release()` on the three post-queue abandoned branches.**
The minimal, correct fix. After `confinedHandler`/`smb2_queue_pdu`/`smb2_connect_share_async`
succeeds, the PDU is registered and libsmb2 owns `cbPtr`. The branch will: clear
`cb.continuation`, resume the continuation with `CancellationError()`, and `return` — leaving the
`+1` for `generic_handler`. The retain is still balanced exactly once (reply or destroy).

*Alternative considered — release the retain AND remove the PDU from libsmb2:* rejected. libsmb2
has no supported API to dequeue/free a single in-flight client PDU and synchronously fire its
callback; freeing the PDU pointer externally races the servicing loop and corrupts the queues.

*Alternative considered — synchronously fire `generic_handler` ourselves on cancel:* rejected.
libsmb2 will still fire the real callback later → double-fire/double-free.

**D-2: Preserve the `cb.isAbandoned` guard ordering.** The guard remains the mechanism that
prevents double-resume of the continuation. Only the erroneous `release()` is removed; the
`continuation = nil` / `resume(throwing:)` / `return` logic is unchanged.

**D-3: Keep the legitimate releases.** The setup error paths that release before any PDU is
queued stay as-is: `context == nil` (`:930`,`:1030`,`:1231`), `confinedHandler`/`smb2_queue_pdu`
threw (`catch` at `:966`,`:1065`), `smb2_set_transport` failed (`:1252`), `connectResult < 0`
(`:1291`), legacy connect `result < 0` (`:617`). In all of these libsmb2 never received `cbPtr`,
so the caller must balance the retain.

**D-4: `connectWithBridge` keeps its `teardownSeam()` call on the abandoned branch.** Removing
only the `release()` is sufficient; tearing the seam down (closing the bridge, cancelling timers)
is still correct and the pending connect callback is fired through libsmb2's internal connect
chain at `smb2_destroy_context` (init.c connect_cb / c_data->cb propagation), balancing the
retain at `deinit`. Verified by the architect against the vendored source: the seam connect
stores `generic_handler`/`cbPtr` in `connect_data->cb` (not as a direct PDU cb); at destroy the
in-flight NEGOTIATE/SESSION_SETUP/TREE_CONNECT sub-step PDU's internal cb fires with
`SMB2_STATUS_SHUTDOWN` and propagates to `c_data->cb` (our `generic_handler`) then `free_c_data`
(which nulls `connect_data` so init.c does not re-run it), while `ext_connect` nulls
`smb2->connect_cb` after firing it — so our handler fires **exactly once** at destroy. No
double-fire, no leak.

**D-6: Fence the remaining members of the bug class (release-after-queue).** The two `catch`
releases that survive — `async_await` (~966) and `async_await_pdu` (~1065) — are reachable ONLY
before a PDU is queued (the `try` body that can throw is the libsmb2 async/queue call itself, and
on throw nothing was registered). A code comment at each site MUST state: "Reachable only before
the PDU is queued; never add a throwing call after `smb2_*_async`/`smb2_queue_pdu` success or this
becomes the same double-free." This is cheap insurance against re-introducing the bug class the
three removed releases represent.

**D-7: Known accepted quirk (pre-existing, made non-crashing by the fix).** If the synchronous
`ext_connect → connect_cb → smb2_cmd_negotiate_async` path returns NULL (ENOMEM) during
`smb2_connect_share_async`, `generic_handler` can fire *synchronously inside* that call (which
still returns 0). With the OLD code that is a double-release (crash); with the fix it is safe —
`isAbandoned` is observed at line 1306 and the caller resumes with `CancellationError` instead of
the true ENOMEM error. A minor error-fidelity loss on an allocation-failure race, accepted.

**D-5: Verification strategy.**
- *Deterministic unit test that EXECUTES the real branch* (no server, Apple seam): drive the
  `connectWithBridge` post-queue abandoned branch (line 1306/1308) directly. Use a gated test
  transport whose `connect()` suspends until the test signals; cancel the task while suspended in
  `bridge.connect()` so `withTaskCancellationHandler` is entered already-cancelled — then `onCancel`
  enqueues `isAbandoned=true` on the serial `eventLoopQueue` *ahead of* the setup block, making the
  setup block hit the abandoned branch deterministically (after NEGOTIATE is queued). Assert it
  throws `CancellationError`, `pendingSeamOperationCount == 0`, and — the regression assertion —
  that subsequent client teardown (`deinit`/`disconnect`) does NOT crash. Under the OLD code this
  branch frees `CBData` after the PDU is queued, so `smb2_destroy_context` at `deinit` fires
  `generic_handler` → `takeRetainedValue` on freed memory → UAF (ASan-detected, and can crash even
  without ASan). Under the fix the retain is balanced exactly once. This test runs the genuine
  production code path, satisfying the review gate's test-fidelity condition.
- *Honest scope note:* the `async_await` / `async_await_pdu` read/op branches are the SAME one-line
  fix but cannot be driven deterministically without a negotiated SMB2 session (a live server) —
  `MockTransport` cannot speak real SMB2. They are covered by: (a) the connect-branch test above,
  which exercises the identical pattern; (b) the integration stress harness below; (c) the
  swift-code-reviewer checklist item confirming `.release()` is removed at all three post-queue
  sites. The unit test does NOT claim to execute the `async_await` branch.
- *Integration stress harness* (skipped without `SMB_SERVER`): spawn many concurrent reads of a
  sizeable file and cancel their tasks at randomized sub-read delays in a tight loop, ideally
  against a throttled share, run under ASan/TSan. Proves absence of the UAF empirically. If no
  Docker/live server is available in the build environment, the ASan stress run is recorded as
  DEFERRED to a Docker-capable host — not silently skipped.

## Risks / Trade-offs

- **[Residual leak if a reply never arrives AND the context is never destroyed]** → In practice
  `deinit` always runs `smb2_destroy_context`, which fires the pending callback and balances the
  retain. Same bound as the existing `onCancel`/buffer-abandon paths; not a new risk.
- **[Race is timing-dependent and not deterministically reproducible end-to-end]** → Mitigated by
  the deterministic unit test on the invariant plus the sanitizer stress harness. Honest residual
  uncertainty is documented: the stress harness raises confidence but cannot prove the absence of
  all orderings; the unit test proves the specific ownership fix.
- **[`smb2_destroy_context` callback-firing assumption]** → Verified directly in vendored libsmb2
  source (init.c:323-351). Pinned via submodule; a future libsmb2 bump should re-verify.

## Migration Plan

Source-only change; no migration. Rollback = revert the commit. Ship as a pre-release version
bump (current scheme `5.99.x`) so the consuming app can validate on-device before promotion.

## Architectural guidance for consumers (pool / lease lifetime)

After this fix, releasing a lease / recycling an `SMB2Client` while reads are in flight is
**UAF-safe**: a late `read_cb` writes into a leaked-but-valid `RawBuffer`, and `generic_handler`
balances the retain and returns early on `isAbandoned`. However, `disconnect()` (Context.swift:
632-663) tears down the seam and fails pending operations but does **not** destroy/nil the
context — so a cancelled/abandoned in-flight read's `CBData` and abandoned `RawBuffer` remain
allocated until `deinit` runs `smb2_destroy_context`. This is a bounded leak window, not a crash.

Guidance: long-lived pools that recycle clients should prefer constructing a **fresh** client
(full `deinit` → `smb2_destroy_context`, which drains pending PDUs) over `disconnect()` + reuse of
the same instance, to avoid both the leak window and any interaction with stale queued PDUs left
in libsmb2's queues by `disconnect()`.

## Open Questions

- Should `disconnect()` proactively `smb2_destroy_context` (or otherwise drain) so abandoned
  in-flight reads are balanced immediately rather than at `deinit`? Out of scope here (leak, not
  crash), tracked as a potential follow-up change if pool reuse holds clients connected for long
  periods.
- Separate, unverified, explicitly OUT OF SCOPE: whether `write`/`pwrite` (FileHandle.swift)
  handing `withUnsafeBytes` `baseAddress` to `smb2_write_async` is safe depends on whether libsmb2
  copies the write payload at queue time. Flagged by the architect as a candidate for a future
  independent audit; not touched by this change.
