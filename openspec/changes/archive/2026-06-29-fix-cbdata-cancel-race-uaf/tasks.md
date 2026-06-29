## 1. Regression test (TDD — Red)

- [x] 1.1 Add an Apple-seam unit test (no server) that EXECUTES the real `connectWithBridge`
      post-queue abandoned branch (Context.swift ~1306/1308) deterministically: use a gated test
      transport whose `connect()` suspends until signalled; cancel the task while suspended in
      `bridge.connect()` (so `withTaskCancellationHandler` is entered already-cancelled and
      `onCancel` enqueues `isAbandoned=true` ahead of the setup block on the serial event-loop
      queue). Assert it throws `CancellationError`, `pendingSeamOperationCount == 0`, the client is
      not connected, AND that subsequent teardown (`deinit`) does not crash (the UAF regression
      assertion — ASan-detected). Must fail/crash under the current `release()`-on-abandon code.
- [x] 1.2 Add an integration stress harness in `AMSMB2Tests/` (inherits `SMBIntegrationTestCase`,
      skipped without `SMB_SERVER`): submit many concurrent reads of a sizeable file and cancel
      their tasks at randomized sub-read delays in a tight loop; assert no crash and clean
      teardown. Document it is intended to run under ASan/TSan; if no Docker/live server is
      available, record the sanitizer run as DEFERRED to a Docker-capable host (do not claim
      passing).

## 2. Fix (TDD — Green)

- [x] 2.1 `async_await` (Context.swift ~943): in the post-queue `guard !cb.isAbandoned else`
      branch, remove `Unmanaged<CBData>.fromOpaque(cbPtr).release()`. Keep `cb.continuation = nil`,
      `continuation.resume(throwing: CancellationError())`, `return`. Add a comment: libsmb2 owns
      `cbPtr` once the PDU is queued; the single balance is `generic_handler`'s
      `takeRetainedValue`, guaranteed by `smb2_destroy_context`'s teardown sweep.
- [x] 2.2 `async_await_pdu` (Context.swift ~1043): same removal in the post-`smb2_queue_pdu`
      abandoned branch, with the same comment.
- [x] 2.3 `connectWithBridge` (Context.swift ~1308): same removal in the post-
      `smb2_connect_share_async` abandoned branch; keep the `teardownSeam()` call and the
      `CancellationError` resume.
- [x] 2.4 Fence the bug-class siblings: add a comment at the two surviving `catch` releases
      (`async_await` ~966, `async_await_pdu` ~1065) stating they are reachable ONLY before the PDU
      is queued, and that no throwing call may be added after `smb2_*_async`/`smb2_queue_pdu`
      success or it becomes the same double-free.
- [x] 2.5 Verify the legitimate pre-queue release sites are unchanged (context nil at ~930/~1030/
      ~1231; `smb2_set_transport` failure ~1252; `connectResult < 0` ~1291; legacy connect
      `result < 0` ~617).

## 3. Verify

- [x] 3.1 `swift build --disable-sandbox` and `swift test --disable-sandbox` — unit tests green
      (including the new connect-branch test), integration tests skip cleanly without a server.
- [x] 3.2 Cross-platform verification (no regressions):
      - macOS: `swift build` clean; `swift test` → 157 passed / 51 skipped / 0 failures.
      - iOS Simulator (iPhone 17 Pro): `xcodebuild build -scheme AMSMB2` → exit 0 (Apple-seam
        triple, incl. `connectWithBridge`). Only pre-existing libsmb2 C / Directory.swift warnings.
      - Linux (Docker, aarch64-unknown-linux-gnu, Swift 6.1.3): `swift test` → 116 passed /
        51 skipped / 0 failures (exercises the shared `async_await`/`async_await_pdu` edits on the
        `#if !canImport(Network)` legacy path; Apple-only seam tests correctly excluded).
      - NOTE: the `./scripts/build.sh`/`./scripts/test.sh` referenced in the task live in the
        consuming app repo, not here; this repo uses `swift build/test --disable-sandbox` +
        `xcodebuild` + `make linuxtest` (the latter needed an absolute `-v` mount on this Docker).
- [x] 3.3 Run the new connect-branch test and the integration stress harness under
      AddressSanitizer (TSan if feasible). Record evidence: crash/ASan report before the fix where
      reproducible; clean after. If Docker/live server is unavailable here, mark the
      server-dependent ASan run DEFERRED rather than skipped.
      EVIDENCE — connect-branch test `testCancelledSeamConnectAfterQueueDoesNotUseAfterFreeOnTeardown`:
      - BEFORE fix (release on abandoned branch present): ASan `heap-use-after-free` at
        `Context.swift:862` in `generic_handler` (`takeRetainedValue()`/`isAbandoned` access);
        also crashes without ASan (SIGSEGV, signal 11).
      - AFTER fix: passes clean under `swift test --disable-sandbox --sanitize=address
        --filter SMB2CBDataLifetimeTests`. Full `SMB2ServicingLoopTests` also green under ASan.
      - Integration stress harness `SMB2CancelStressTests` ASan/TSan run is DEFERRED to a
        Docker/live-server host (`SMB_SERVER` unset here → test skips).
- [x] 3.4 swift-code-reviewer review of the diff. VERDICT: APPROVE. Confirmed `.release()` removed
      at exactly the three post-queue sites; all 8 pre-queue release sites intact; fence comments
      present and accurate. Reviewer independently re-ran the ASan RED/GREEN proof (reintroduced the
      old release → `heap-use-after-free Context.swift:862`; reverted → clean) and verified the
      exactly-once guarantee against libsmb2 source (transport-external.c:147, init.c:323-360). Only
      two non-blocking NITs (comment line length within the 132 hard limit; test-ordering coverage
      assumption documented) — no changes required, so the address/re-review cycle is a no-op.

## 4. Documentation & artifacts

- [x] 4.1 Proposal/design/specs match what shipped: three post-queue `.release()` removed +
      two `catch` fences; deterministic connect-branch test + deferred integration stress harness.
      The honest note that the `async_await`/`async_await_pdu` read branches are not
      deterministically reproducible end-to-end without a server is retained in design.md (D-5).
- [x] 4.2 Add a firm, specific gotcha to `CLAUDE.md`: "Never
      `Unmanaged<CBData>.fromOpaque(cbPtr).release()` after the PDU is queued; the single balance
      is `generic_handler`'s `takeRetainedValue`, guaranteed by `smb2_destroy_context`'s teardown
      sweep."
