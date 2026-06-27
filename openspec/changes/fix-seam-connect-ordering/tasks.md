# Tasks

TDD is mandatory for code tasks: the failing seam integration suite is the **red**. Write/confirm
the failing test from the linked spec scenario first, then make it green. The architect MUST select
Approach A or B (design.md) before C1 implementation begins.

## C0 — Architect decision gate [transport-connect-ordering]

- [x] 0.1 `project-architect` reviewed `design.md` and selected **Approach A (eager connect)**;
  Approach B rejected (blocks `eventLoopQueue` on connect RTT). Sequencing: **Apple stays
  seam-only** (option i). Decision + rationale recorded in `design.md` → "Architect Decision
  (2026-06-26, review gate)" (D-FIX-1, D-FIX-2) with binding correctness mandates.
- [x] 0.2 Update `proposal.md` "What Changes" to state Approach A and remove Approach B,
  keeping artifacts honest

## C1 — Reproduce the defect as a failing test (red) [transport-connect-ordering]

- [x] 1.1 Confirmed `SMB2SeamIntegrationTests` failed against live Samba with the documented
  symptom (`POSIXError(.init(1))` / `ENOTCONN` code 57) — baseline red captured before the fix.
- [x] 1.2 (TDD, unit) Readiness invariant pinned in
  `TransportBridgeTests.testConnectTrampolineReportsStateOnly`: the `ext.connect` trampoline
  reports failure (`< 0`) before the transport connects and `0` only after `bridge.connect`
  succeeds. (Failed on the old unconditional `kickConnect` return-0.)
- [x] 1.3 (TDD, unit)
  `SMB2SeamConnectOrderingTests.testConnectFailurePropagatesAndDoesNotRegisterOperation`: a failing
  transport `connect` makes `connectWithBridge` throw the mapped `POSIXError` (`.ECONNREFUSED`, not
  `EPERM`), with no operation registered (client stays not-connected). Companion real-transport
  test `SMB2ServicingLoopTests.testEagerSeamConnectToUnreachableEndpointFailsFast` bounds the
  failure by the transport connect timeout.

## C2 — Implement the fix (green) [transport-bridge / transport-servicing]

- [x] 2.1 Added `TransportBridge.connect(host:port:) async throws` (sets `isPreConnected` under
  `lock` via the sync helper `markPreConnected()`; `transport` stays `private`). `connectWithBridge`
  parses host/port via `SMB2Client.parseSeamEndpoint(_:)` (mirrors `ext_connect`) and `await`s
  `bridge.connect(...)` before `smb2_set_transport`; failure is mapped via
  `mapTransportConnectError` and thrown with no operation registered.
- [x] 2.2 The `ext.connect` trampoline returns `bridge.connectStatus()`
  (`isPreConnected ? 0 : -ECONNREFUSED`) and performs no connect; the fire-and-forget
  `Task { try? await ... }` / `kickConnect` is deleted and the stale doc comment replaced.
- [x] 2.3 Teardown-on-early-failure: both the `context == nil` guard and the
  `smb2_set_transport != 0` guard now call `bridge.close()` (closes the eagerly-connected
  transport/pumps) in addition to balancing the `Unmanaged` — no double-release (close touches only
  transport/pumps; the `Unmanaged.release()` balances the bridge retain separately).
- [x] 2.4 (TDD) Parser table covered by
  `SMB2SeamConnectOrderingTests.testParseSeamEndpointTable` + `testParseSeamEndpointMissingBracketThrows`
  (`host`, `host:1445`, `[::1]`, `[::1]:1445`, `[bad`→`EINVAL`, `127.0.0.1:445`, `127.0.0.1`).
- [x] 2.5 Exactly-once connect: the transport connects only in `bridge.connect`; the trampoline
  (`connectStatus()`) reports state and never reconnects. The `ext_close` once-semantics / single
  `takeRetainedValue()` contract is untouched.
- [x] 2.6 `swift build --disable-sandbox` and `swift test --disable-sandbox` pass (144 unit tests,
  0 failures, 50 integration skipped without a server); no new Swift 6 concurrency warnings
  (the only warning, Context.swift:972 `#SendableClosureCaptures`, is pre-existing on the legacy
  async_await path).

## C3 — Live seam acceptance against Docker Samba [transport-connect-ordering]

- [ ] 3.1 Bring up the fixture, wait for port 445, run the seam suite, then **always** tear down:

  ```bash
  docker-compose -f test-fixtures/docker-compose.yml up -d
  for i in $(seq 1 30); do nc -z 127.0.0.1 445 && break; sleep 1; done
  SMB_SERVER=smb://127.0.0.1 SMB_SHARE=testshare SMB_USER=testuser SMB_PASSWORD=testpass \
    SMB_TRANSPORT=seam swift test --disable-sandbox --filter SMB2SeamIntegrationTests 2>&1 | tail -50
  docker-compose -f test-fixtures/docker-compose.yml down -v
  ```

- [x] 3.1 Ran the Docker Samba fixture and the seam suite, then tore the fixture down.
  `SMB2SeamIntegrationTests`: 5 ran, 0 failures (1 deferred skip — `testBothWaysComparison`).
- [x] 3.2 All seam scenarios pass: connect/NTLM (`testConnectAndAuthenticate`), directory listing,
  large read/write (5 MiB+7 via the data API), cancel (`testCancelInFlightOperation`).
- [x] 3.3 `smb2_get_fd == -1` asserted on the seam connection
  (`testSeamConnectionHasNoFileDescriptor`, green).
- [x] 3.4 Full Apple suite over the seam (`SMB_TRANSPORT=seam`): 144 tests, 1 unrelated failure.
  - `SMB2IntegrationTests.testSmbClientAccessorAfterConnect` initially failed because the public
    `smbClient` accessor gated on `fileDescriptor != -1`, which is always false for a seam
    connection (no native fd). Fixed by gating on the seam-aware `isConnected` predicate
    (`AMSMB2/AMSMB2.swift`) — a T9 seam-only end-state correction. Now green.
  - **OUT OF SCOPE — separate pre-existing bug:** `SMB2ManagerTests.testStreamUploadDownload`
    truncates uploads at exactly 5 MiB. Root cause is `AsyncInputStream.read()`
    (`AMSMB2/Stream.swift:174`) setting `_streamStatus = .atEnd` when the consumer drains the
    *currently-buffered* bytes without checking whether the prefetch producer has finished — the
    "premature EOF when consumed faster than prefetch fills" race already documented in CLAUDE.md.
    It is in the stream helper (unrelated to connect ordering) and is **independently confirmed
    unrelated to seam I/O**: `SMB2SeamIntegrationTests.testLargeWriteThenRead` round-trips 5 MiB+7
    via the *data* API over the same seam and passes. Recommend a dedicated OpenSpec change to fix
    the `AsyncInputStream` EOF/would-block semantics; not addressed here per the minimal-scope
    mandate.

## C4 — T8/T9 reconciliation: keep rollout artifacts honest [transport-rollout]

- [ ] 4.1 Annotate the archived rollout `tasks.md` T8.3 as superseded by
  `fix-seam-connect-ordering` (Apple has no legacy path; A/B-on-one-platform comparison is
  impossible), pointing to this change's `design.md`
- [ ] 4.2 Re-scope the equivalence claim to "Linux legacy vs Apple seam, same server, same
  assertions" and restate the Apple acceptance criterion as "seam suite green"; reflect in the
  rollout spec/design so no artifact asserts a non-existent Apple legacy path

## C5 — Review and verification [transport-connect-ordering]

- [ ] 5.1 `swift-code-reviewer` review (correctness + simplification); confirm no dead code, no new
  warnings, `POSIXError(.CODE)` error style, 4-space indent
- [ ] 5.2 Address review findings; re-run unit + live seam suite
- [x] 5.3 Agent memory updated: new `patterns_seam_connect_ordering.md` (root cause, eager-connect
  fix, parser rules, teardown-on-early-failure, seam-fd-is-always-`-1` gotcha, and the out-of-scope
  AsyncInputStream race) + MEMORY.md index entry.
- [ ] 5.4 Do NOT commit until the user requests it
