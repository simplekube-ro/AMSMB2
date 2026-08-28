## Why

Against a real Windows Server 2022 SMB-over-QUIC host with a self-signed certificate
(`win2k22.kaveman.intra`, 2026-08-28), the default `.system` trust policy correctly rejects the
certificate — but the caller only learns this after the full `connectTimeout` (30 s by default)
elapses, as `POSIXError(.ETIMEDOUT)` with the real cause buried in the description string
(`"…; last waiting error: … QUIC TLS error: -9808: bad certificate format"`). The same symptom was
already recorded against the Samba/libquic rig (`docs/INTEROP-QUIC.md`, "TLS trust rejection
surfaces as the connect deadline"), so this is Network.framework behavior, not a server quirk:
`NWConnection` reports a TLS handshake/trust rejection as the *non-terminal* `.waiting(.tls(_))`
state, and the transport's connect state machine (design D7 of `add-quic-transport`) treats every
`.waiting` as transient. A trust rejection is deterministic — the same policy and the same server
certificate can never later succeed — so waiting out the deadline is pure latency, and reporting
it as a timeout makes it indistinguishable from an unreachable server. Apps cannot offer a
"this server's certificate is not trusted" flow without string-matching.

## What Changes

- The QUIC connect state machine SHALL classify `.waiting` events by error class: a TLS
  handshake/trust rejection is **fatal** and claims the connect outcome immediately, exactly like
  `.failed`; every other `.waiting` (no route, DNS, `ECONNREFUSED`, …) remains **transient** and
  keeps the existing keep-waiting-until-deadline behavior.
- The classification lives at the driver-neutral connection-driver seam, so the scripted test
  double can emit both classes deterministically and the D7 race/ownership proofs apply unchanged.
- The `POSIXError` produced for a TLS rejection SHALL carry the underlying Security OSStatus as
  `NSUnderlyingErrorKey` (`NSOSStatusErrorDomain`), so callers can distinguish a TLS/trust
  rejection from other `EPROTO` failures without parsing the description. The top-level code
  stays `EPROTO` (no new error types — project convention).
- The deadline description keeps mentioning the last *transient* waiting error (unchanged).
- Documentation and the live interop tests that codified the old "trust rejection == `ETIMEDOUT`"
  behavior are updated to assert the prompt `EPROTO` failure instead.
- Not a public API change: no new types, no new `SMBQUICConfiguration` fields. Behavioral change
  only for callers that were relying on a trust rejection surfacing as `ETIMEDOUT` (undocumented
  as a contract; documented as a known limitation).

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `quic-transport-apple`: the "connect claims its outcome atomically" requirement changes its
  `.waiting` handling from "always non-terminal" to "classified transient vs fatal"; a new
  requirement defines the prompt, distinguishable TLS-rejection error contract.
- `api-reference`: the QUIC error enumeration and the error-code table gain `EPROTO` (TLS
  rejection, with `NSUnderlyingErrorKey`) and `ETIMEDOUT` is narrowed to "endpoint unreachable /
  unresponsive".

## Impact

- `AMSMB2/QUICTransportApple.swift`: `QUICConnectionState.waiting` payload (seam), `mapState`,
  `NWError.asQUICPOSIXError`, `handleState`.
- `AMSMB2Tests/QUICTransportAppleTests.swift`: scripted-driver tests for fatal vs transient
  `.waiting`; `NWError` mapping test for the underlying-error payload.
- `AMSMB2Tests/SMB2QUICInteropTests.swift`: `testTrustSystemRejectsLabCert` /
  `testTrustUnrelatedAnchorRejected` (and the `requireRigReachable` rationale) assert `EPROTO`
  promptly instead of tolerating the deadline.
- `docs/INTEROP-QUIC.md`: the "TLS trust rejection surfaces as the connect deadline" trap becomes
  a resolved note; add the Windows Server 2022 interop observation.
- `docs/API.md`: the `connectTimeout` callout ("does not fail fast … surfaces as
  `POSIXError(.ETIMEDOUT)`") is rewritten; the error-code table drops the "TLS-trust rejection
  also surfaces here" note from the `ETIMEDOUT` row and gains an `EPROTO` row (Darwin errno 100).
- `docs/ARCHITECTURE.md`: the QUIC "Connect state machine" paragraph's state list (`.waiting`
  non-terminal) and error contract are updated for the transient/fatal classification.
- No dependency, package-manifest, or Linux impact (`#if canImport(Network)` only).

## Review

**Verdict:** APPROVED WITH CONDITIONS
**Reviewer:** project-architect
**Date:** 2026-08-28

The three core decisions are sound and I endorse them: D1 (classify at the driver-neutral seam),
D2 (fatal waits reuse `handleFailed` verbatim), D3 (`EPROTO` + `NSUnderlyingErrorKey`, no new
error type). I traced the claim/handoff machinery and confirm D2 preserves the D7/D8/D12
guarantees by construction (see O1). The conditions below are gaps in artifact coverage and task
sequencing, not in the mechanism.

### Conditions (address before `/opsx:apply` completes; artifacts must reflect them)

1. **Missing documentation impact.** Two shipped docs assert the old contract and are not in the
   Impact list or `tasks.md`:
   - `docs/API.md` ~line 649 — the callout "a verify-failed QUIC handshake ... does not fail fast
     ... surfaces as `POSIXError(.ETIMEDOUT)`" becomes actively false;
   - `docs/API.md` ~line 715 — the `ETIMEDOUT` row's "note a QUIC TLS-trust rejection also
     surfaces here" must go, and an `EPROTO` row must be added (`EPROTO` currently appears
     nowhere in `docs/` or `openspec/specs/`);
   - `docs/ARCHITECTURE.md` line 263 — the connect-state-machine paragraph states "`.waiting`
     non-terminal, error recorded" and an error contract ending "`.failed` → mapped
     `POSIXError`"; both need the transient/fatal split.
   Add these to the proposal's Impact section and as tasks under section 4, each with a
   verification clause.

2. **Missing delta spec for `api-reference`.** `openspec/specs/api-reference/spec.md` enumerates
   the QUIC connect error codes in the "QUIC policy and errors are documented" scenario (line 21)
   and the "Error documentation" requirement (line 49); neither lists `EPROTO`. Both lists are
   introduced with "including", so this is not a hard contradiction — but `docs/API.md` *is*
   governed by that capability and must change, so add a MODIFIED delta for `api-reference` that
   inserts `EPROTO` (QUIC TLS/trust rejection, underlying `NSOSStatusErrorDomain` status). Keeping
   the doc and its spec in step is cheaper now than as archive drift.

3. **The production classification has no test.** `NWConnectionQUICDriver.mapState` is the single
   line that decides `.tls → .fatal` in production, and task 3.2 bundles it with the error-shape
   implementation without a test of its own. The scripted-driver tests (1.3, 2.2, 2.3) prove the
   *transport dispatch* but inject `QUICConnectionState` directly and therefore never exercise
   `mapState`. Add a task, ordered before 3.2, for a direct `mapState` test asserting:
   `.waiting(NWError.tls(-9808))` → waiting/fatal carrying `EPROTO` + the underlying error;
   `.waiting(NWError.posix(.ECONNREFUSED))` → waiting/transient; `.failed(NWError.tls(...))` →
   failed (unchanged shape).

4. **Drop the `tlsError(status:)` seam proposed in D5.** Its stated premise — "`NWError.tls`
   cannot be constructed in tests" — is incorrect: the macOS SDK's `Network.swiftinterface`
   declares `public enum NWError { case posix(POSIXErrorCode); case dns(DNSServiceErrorType);
   case tls(Darwin.OSStatus); ... }`, so `NWError.tls(-9808)` is constructible from a test. The
   only real obstacle is access level: `NWError.asQUICPOSIXError()` is `fileprivate` and
   `mapState` is `private static`. Relax both to `internal` — `@testable import AMSMB2` reaches
   them — rather than introducing a new symbol whose only non-definition call site would be a
   test (which the dead-code-prevention gate in CLAUDE.md exists to prevent). Update D5 and task
   3.1 to the access-relaxation approach.

5. **Task TDD labelling is inconsistent.** Tasks 1.2 and 2.2 both say "write a failing unit test"
   and then, in the same bullet, require them to pass ("verify it passes unchanged after 1.1";
   "should pass via `handleFailed` reuse"). They are GREEN regression/characterization tests, not
   RED steps — relabel them, and label 2.3 the same way. Keep 1.3, 3.1 and the new task from
   condition 3 as the genuine RED steps so the cycle state of each task is unambiguous.

6. **Loosen or drop the live wall-clock assertion (task 4.1).** `EPROTO` alone proves fail-fast:
   the deadline path can only ever produce `ETIMEDOUT`, never `EPROTO`, so an `elapsed < 5 s`
   assertion adds no information and only adds flake risk on a loaded rig or CI host. Record the
   measured elapsed time as a log line, or bound it at the full 8 s `connectTimeout`.

7. **Reconsider D4's `lastWaitingError` narrowing.** Recording `lastWaitingError` only for
   transient waits means that in the narrow fatal-wait-loses-to-deadline race, the resulting
   `ETIMEDOUT` description silently loses the TLS status that today's code *does* surface —
   a diagnostic regression precisely in the case that is hardest to debug. Recommended: record
   `lastWaitingError` for every `.waiting` regardless of class (it is a pure diagnostic string,
   costs no extra branch, and strictly improves the losing-race message), and revert the delta
   spec's "Deadline expiry" scenario and the requirement prose to "the last `.waiting` error".
   If D4 is kept as written, it must state explicitly that the TLS status is knowingly discarded
   in that race.

### Observations (no action required)

- **O1 — D2 verified against the claim machinery.** Routing `.waiting(_, .fatal)` into
  `handleFailed` preserves all three phases: (a) connect phase → `resolveConnect(.failed)`;
  (b) commit-to-start window → `consumeLossClaimLocked` sees `startPhase == .starting`, parks
  `pendingLoss` and returns `nil`, so `resolveConnect` performs *no* side effect and notably does
  not cancel the deadline — the post-start handoff in `runConnectAttempt` does the single
  deadline-cancel, single `driver.cancel()`, then resumes, with `connectWorkInFlight` still
  spanning it so `close()` still waits (D12 intact); (c) post-ready → `.ready where lifecycle ==
  .active` → abnormal loss to the receive waiter (D8 intact). Repeated `.waiting(.tls)` — which
  `NWConnection` does re-emit — is idempotent: the second delivery finds `connectState == .failed`
  or `lifecycle == .failed` and hits `.ignore`, so no double cancel and no double resume. A
  pre-commit fatal wait (`startPhase == .notStarted`) cannot arise in production (the driver only
  emits from inside/after `start`) but the scripted seam can produce it, and it degrades safely to
  "forbid the start, nothing to cancel".
- **O2 — third-order sweep is clean.** No error-keyed transport fallback exists: `Context.swift`'s
  `seamSelector`/`seamDefaultPort` map `.automatic` to TCP unconditionally ("`.automatic` never
  yields QUIC"), so changing the QUIC connect error code cannot alter transport selection.
  `SMB2Manager`'s `NSSecureCoding`/`Codable` surface is untouched (no new stored state).
  `QUICConnectionState` has no consumers outside `AMSMB2/QUICTransportApple.swift` and the four
  test doubles in `AMSMB2Tests/QUICTransportAppleTests.swift`, so the enum-shape change is fully
  contained. Linux is unaffected (`#if canImport(Network)`).
- **O3 — the seam is the right layer.** Adding `QUICWaitClass` is defensible precisely because it
  is *preserved translation information*, not policy: it is the one bit of the `NWError` case that
  survives the `POSIXError` erasure, while the policy ("fatal ⇒ claim the outcome as failure")
  stays in `handleState`. Frame it that way in the `QUICConnectionState` doc comment so the seam's
  "NWConnection-shaped, Network-framework-free" contract stays honest. D1's rejection of
  driver-level reinterpretation into `.failed` is accepted.
- **O4 — delta spec fidelity confirmed.** I diffed the MODIFIED requirement against
  `openspec/specs/quic-transport-apple/spec.md`: it is a faithful full copy apart from the
  intended edits — the `.waiting` clause, the error-contract sentence, "a transient `.waiting`" in
  "Cancellation while waiting", "last transient `.waiting` error" in "Deadline expiry", and three
  added scenarios. No scenario dropped, no unintended edit. One carried-over nit worth fixing
  while in the file: the closing NOTE's "(tasks 2.3)" is a stale reference to the archived
  `add-quic-transport` task numbering and now collides with this change's own task 2.3.
- **O5 — ADDED requirement scope.** "the TLS handshake otherwise cannot complete" correctly also
  captures ALPN mismatch, which is likewise an `NWError.tls` and likewise unhealable by a path
  change. `testQUICOnlyFailureModeNoFallback` (port 4443, asserts only "not `EINVAL`") passes
  either way.
- **O6 — availability.** `NWError.wifiAware` is `@available(macOS 26/iOS 26/...)`. Preserve the
  existing availability guard shape when editing that switch; the classification edit must not
  widen the availability surface of `asQUICPOSIXError` or `mapState`.
- **O7 — `POSIXError(_:userInfo:)` is already in use** (`AMSMB2/Extensions.swift` line 72), so D3
  needs no new initializer; constructing `userInfo` inline in the `.tls` branch rather than
  growing the shared `POSIXError(_:description:)` helper is the right call.

### Conditions addressed (2026-08-28, after review)

1. `docs/API.md` and `docs/ARCHITECTURE.md` added to Impact and to tasks 4.3/4.4.
2. `api-reference` delta spec added (`specs/api-reference/spec.md`), listed under Modified Capabilities.
3. RED task 3.2 added: `mapState` classification (`.tls` → fatal / `.posix` → transient) tested directly.
4. Design D5 no longer introduces a `tlsError(status:)` seam; `asQUICPOSIXError` and `mapState` become
   `internal` for direct testing (`NWError.tls(OSStatus)` is constructible).
5. Tasks 1.2, 2.2, 2.3 relabelled as GREEN regression guards; RED steps are 1.3, 3.1, 3.2.
6. Task 4.1 no longer asserts a wall-clock bound; `EPROTO` alone proves the non-deadline path.
7. Design D4 reversed: `lastWaitingError` is recorded for every `.waiting`; the delta spec keeps the
   original "last `.waiting` error" wording.
