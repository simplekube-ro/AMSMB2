## 1. Seam classification (design D1)

- [x] 1.1 Add `QUICWaitClass` (transient/fatal) to `QUICConnectionState.waiting` and update every emitter/consumer to compile (`ScriptedQUICDriver` and the other test doubles, `mapState`, `handleState`); verify `swift build --disable-sandbox` succeeds and the existing `QUICTransportAppleTests` still pass with `.transient` substituted where `.waiting` was scripted
- [x] 1.2 GREEN regression guard — "transient waiting is non-terminal": scripted driver emits `.waiting(ENETDOWN, .transient)` then `.ready`; assert connect succeeds and the deadline scheduler's `fire` was never invoked (adapt `testWaitingIsNonTerminalThenReadySucceeds`); verify it passes after 1.1 and stays green through section 2
- [x] 1.3 RED — "fatal waiting fails fast": scripted driver emits `.waiting(EPROTO, .fatal)`; assert connect throws that `POSIXError` before the scheduler fires (scheduler `cancel()` observed, `fire` never invoked), the driver's `cancel()` count is exactly 1, and the continuation resumes exactly once; verify RED with `swift test --disable-sandbox --filter QUICTransportAppleTests`

## 2. Transport dispatch (design D2, D4)

- [x] 2.1 In `handleState`, record `lastWaitingError` for every `.waiting`, then route `.fatal` to `handleFailed` and return for `.transient`; verify 1.3 goes GREEN and 1.2 stays green
- [x] 2.2 GREEN regression guard — "fatal waiting in the commit-to-start window is a parked loss" using the existing gated-start driver: fatal wait delivered before `start` returns; assert no cancel/resume inside the window and exactly one cancel + one resume with the fatal error after `start` returns; verify GREEN (expected to pass via `handleFailed` reuse — if it fails, fix the dispatch, not the test)
- [x] 2.3 GREEN regression guard — "post-ready fatal waiting routes to the receive path" (mirror of the existing post-ready `.failed` test); verify GREEN
- [x] 2.4 GREEN regression guard — "fatal wait after the deadline is a side-effect-free loser": scripted driver emits `.waiting(EPROTO, .fatal)` only after the scheduler has fired; assert `ETIMEDOUT` stands, the driver is cancelled exactly once, and the continuation is not resumed again; verify GREEN. (Amended during apply: the originally-specified "description contains the fatal text" assertion is unprovable in that ordering — the `ETIMEDOUT` description is built inside `resolveConnect(.deadline)` at claim time, so a wait emitted *after* the deadline can never appear in it, and a fatal wait emitted *before* the deadline claims the outcome itself. D4's every-class `lastWaitingError` recording is implemented but has no deterministic seam test; see design D4.)

## 3. Error shape and production classification (design D3)

- [x] 3.1 RED — TLS mapping: make `NWError.asQUICPOSIXError` `internal`; test that `NWError.tls(-9808).asQUICPOSIXError()` is `POSIXError(.EPROTO)`, `userInfo[NSUnderlyingErrorKey]` is an `NSError` with `domain == NSOSStatusErrorDomain` and `code == -9808`, and the description contains `"-9808"`; verify RED
- [x] 3.2 RED — production classification: make `NWConnectionQUICDriver.mapState` `internal`; test that `mapState(.waiting(.tls(-9808)))` yields `.waiting(_, .fatal)` carrying the 3.1 error shape, and `mapState(.waiting(.posix(.ECONNREFUSED)))` yields `.waiting(_, .transient)` (also `.dns` → transient if constructible); verify RED
- [x] 3.3 Implement the `.tls(status)` branch of `asQUICPOSIXError` (direct `userInfo` construction, no shared-helper growth) and the `.tls` → `.fatal` / otherwise `.transient` classification in `mapState`; verify 3.1 and 3.2 GREEN and `swift test --disable-sandbox` (full unit suite) passes with no skips other than the server-gated integration suites

## 4. Live interop and docs (design D5)

- [x] 4.1 Update `SMB2QUICInteropTests.testTrustSystemRejectsLabCert` and `testTrustUnrelatedAnchorRejected` to assert `POSIXError.code == .EPROTO` and a non-nil `NSOSStatusErrorDomain` underlying error (no wall-clock assertion — `EPROTO` alone proves the non-deadline path); update the `requireRigReachable` and file-header comments that describe the old `ETIMEDOUT` behavior; verify the file compiles and the tests still skip cleanly without `SMB_QUIC_SERVER`
- [x] 4.2 Run the trust matrix live against `win2k22.kaveman.intra` (share `Share`, self-signed cert; `.system` must fail fast with `EPROTO`, `.customRoots([server .cer])` and `.insecureNoVerification` must succeed, `.tcp` MD5 must match) — via the interop tests if the env can be pointed at it (`SMB_QUIC_CA_DER` = the server's own `.cer`), otherwise via a scratch harness — and record the outcome (elapsed time of the rejection, status code) in `docs/INTEROP-QUIC.md`
- [x] 4.3 Docs: rewrite the "TLS trust rejection surfaces as the connect deadline" trap in `docs/INTEROP-QUIC.md` as resolved and add the Windows Server 2022 observation; in `docs/API.md` rewrite the `connectTimeout` callout (no longer "does not fail fast"), drop the trust-rejection note from the `ETIMEDOUT` table row, and add an `EPROTO` row (Darwin errno 100, `NSUnderlyingErrorKey` carries the `OSStatus`); verify with `grep -n "EPROTO" docs/API.md` and that no doc still claims trust rejection == `ETIMEDOUT`
- [x] 4.4 Docs: update the QUIC "Connect state machine" paragraph in `docs/ARCHITECTURE.md` (`.waiting` transient vs fatal; error contract adds fatal `.waiting` → mapped `POSIXError`); verify the paragraph matches the delta spec wording

## 5. Verification gate

- [x] 5.1 Run `swift test --disable-sandbox` (full suite) and confirm zero failures and no unexpected skips; run `swift-code-reviewer` per the CLAUDE.md sub-agent pipeline and address findings; confirm `QUICWaitClass` has call sites outside its definition file and no new symbol exists only for tests
