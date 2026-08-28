## Context

See proposal.md — Why. Current shape (all in `AMSMB2/QUICTransportApple.swift`, Apple-only):

```
NWConnection.State ──► NWConnectionQUICDriver.mapState ──► QUICConnectionState ──► QUICTransportApple.handleState
   .waiting(NWError)        error.asQUICPOSIXError()          .waiting(POSIXError)        record lastWaitingError; return
                            (.tls → EPROTO + text;           ▲ driver-neutral seam         ▲ design D7: "only cancel or
                             error CLASS is erased here)     (scripted double in tests)      deadline ends a wait"
```

`QUICConnectionState` is the driver-neutral seam (design D7 of `add-quic-transport`): the
production driver wraps `NWConnection`; unit tests inject `ScriptedQUICDriver` and script states
in any interleaving. `resolveConnect(_:)` is the single atomic claim point; `.failed` reaches it
via `handleFailed`, which also covers the post-ready (D8) and commit-to-start-window (parked
loss) cases. Network.framework delivers a TLS handshake/trust rejection as `.waiting(.tls(status))`
— not `.failed` — because it treats "cannot connect now" generically as retry-on-path-change.
Observed statuses: `-9808` (`errSSLBadCert`) from Windows Server 2022 with a self-signed cert;
the Samba/libquic rig produced different codes for the same class of failure, so the status
value is not stable across servers.

Constraints: errors are `POSIXError` only (CLAUDE.md); no Network.framework types cross the seam;
TDD through the scripted-driver seam, not live servers; the D7 claim/duty proofs must not be
re-derived.

## Goals / Non-Goals

**Goals:**
- A TLS rejection ends the connect attempt as soon as Network.framework reports it, through the
  existing `.failed` claim path, so every D7/D12 race, ownership, and handoff guarantee applies
  without new state-machine logic.
- Keep the seam testable: the scripted double must be able to emit a fatal wait.
- Make TLS rejections machine-distinguishable (`EPROTO` + `NSUnderlyingErrorKey`) without adding
  error types or public API.

**Non-Goals:**
- Fail-fast for non-TLS `.waiting` (`ECONNREFUSED`, DNS, no-route): those are legitimately
  transient on mobile and stay deadline-bounded (D7/D10 unchanged).
- A new "certificate untrusted" error code: Darwin errno has none; `EAUTH` would conflate the
  server's cert being rejected by us with our credentials being rejected by the server.
- Changing `TCPTransportApple`'s `NWError` mapping: SMB over TCP does not negotiate TLS, so its
  `.tls` branch is unreachable in practice; leave it alone (surgical-change rule).
- Any change to `SMBQUICConfiguration`, trust resolution, or `evaluateCustomRootsTrust`.
- A per-status allow/deny list of `OSStatus` values (see D1).

## Decisions

### D1: Classify at the seam, by `NWError` case — `QUICConnectionState.waiting` gains a class

`QUICConnectionState.waiting` carries the class alongside the mapped error:

```swift
enum QUICWaitClass: Sendable { case transient, fatal }
case waiting(POSIXError, QUICWaitClass)
```

(Exact spelling is the implementer's; the requirement is that the seam expresses the class and
the scripted double can emit both.) `mapState` derives it from the `NWError` *case*: `.tls(_)` →
`.fatal`; `.posix`, `.dns`, `.wifiAware`, `@unknown default` → `.transient`.

- Why case, not `OSStatus` value: the same trust failure produced `-9808` on Windows and other
  codes on Samba/libquic — the boringssl→SecureTransport status mapping is not a stable contract.
  Any `.tls` reported in `.waiting` is a handshake outcome that a path change cannot alter.
- Why not classify inside the transport from the mapped `POSIXError`: `asQUICPOSIXError` erases
  the class (`.tls` → `EPROTO` + text); re-deriving it from `EPROTO` would be wrong (other
  sources could produce `EPROTO`) and from description text would be fragile.
- Alternative rejected — driver-level reinterpretation (`mapState` turning `.waiting(.tls)` into
  `.failed`): smallest diff, but hides a semantic decision inside the production driver where
  the scripted double cannot express it, and the spec's "every state handled explicitly" would no
  longer describe what the transport sees. The seam-level class keeps the decision visible and
  unit-testable.

### D2: Fatal waits reuse `handleFailed` verbatim

`handleState(.waiting(error, .fatal))` calls `handleFailed(error)`; `.transient` keeps the
existing record-and-return. No new `resolveConnect` outcome, no new claim state.

- Why: `handleFailed` already encodes the three phases the spec cares about — connect-phase claim,
  commit-to-start-window parked loss (D12 handoff), and post-ready abnormal loss (D8). Routing
  through it means the existing scenarios ("Loss in the commit-to-start window",
  "Failure-versus-cancel race", "Post-ready failure routes to the receive path") hold for fatal
  waits by construction, and the new tests only need to prove the dispatch.
- Post-ready fatal `.waiting`: Network.framework should not emit `.waiting(.tls)` after `.ready`,
  but if it did, D8 treats it as abnormal transport loss — the conservative outcome.

### D3: Error shape — `EPROTO` + `NSUnderlyingErrorKey` (`NSOSStatusErrorDomain`)

`NWError.asQUICPOSIXError` for `.tls(status)` builds
`POSIXError(.EPROTO, userInfo: [NSLocalizedDescriptionKey: "QUIC TLS error: \(status): …",
NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: Int(status))])`. The existing
`POSIXError(_:description:)` helper in `Extensions.swift` only sets the description; the TLS
branch constructs `userInfo` directly rather than growing the shared helper for a single call
site (simplicity rule).

- Why `NSOSStatusErrorDomain`: idiomatic Foundation carrier for `OSStatus`; callers can compare
  against `errSSL*` constants if they want, and `NSError` already prints it usefully.
- Why keep `EPROTO` at the top level: consistent with the existing TCP/QUIC mapping; the
  distinguishing signal callers need most (TLS vs timeout) is already in the top-level code once
  fatal waits stop being reported as `ETIMEDOUT`. The underlying error adds precision without a
  new error type.
- `.tls` is the only `NWError` case that carries an `OSStatus`; `.posix`/`.dns` mappings are
  untouched.

### D4: `lastWaitingError` is recorded for every `.waiting`, transient or fatal

`handleState` records the mapped error for both classes before dispatching (fatal then continues
into `handleFailed`). A fatal wait normally claims the outcome first, so the deadline description
rarely matters — but in the fatal-wait-loses-to-deadline race, which is exactly where diagnosis
is hardest, the `ETIMEDOUT` description still carries the TLS status. Pure diagnostic string, no
extra branch; the spec's "the description includes the last `.waiting` error" wording is
unchanged.

Testability note (from apply): the fatal-wait-loses-to-deadline interleaving cannot be produced
deterministically through the existing seams — the deadline description is built at claim time,
a fatal wait emitted before the deadline wins the claim, and one emitted after it is a no-op. The
recording line is therefore covered only by the transient-wait deadline test
(`testDeadlineExpiryThrowsETIMEDOUT`); `testFatalWaitingAfterDeadlineIsNoOp` covers the
side-effect-free loser half. No gating double was added just to prove a diagnostic string.

### D5: Tests and docs that codified the old behavior are corrected, not deleted

- `QUICTransportAppleTests`: add scripted-driver tests for fatal wait (fails fast, driver cancelled
  once, scheduler cancelled not awaited, continuation resumed once), fatal wait in the
  commit-to-start window (parked loss via the existing gated-start driver), and transient wait
  unchanged (existing `testWaitingIsNonTerminalThenReadySucceeds` updated to the new payload).
  Add direct tests for the production classification and mapping: `NWError.tls(OSStatus)` is a
  public, constructible case, so `mapState(.waiting(.tls(-9808)))` → fatal/`EPROTO`/underlying
  error and `mapState(.waiting(.posix(.ECONNREFUSED)))` → transient are tested as-is. The only
  obstacle is access level: `NWError.asQUICPOSIXError` (`fileprivate`) and
  `NWConnectionQUICDriver.mapState` (`private static`) become `internal`. No new symbol whose only
  non-definition call site would be a test.
- `SMB2QUICInteropTests.testTrustSystemRejectsLabCert` / `testTrustUnrelatedAnchorRejected`:
  assert `EPROTO` with the underlying error; the elapsed time is logged, not asserted — `EPROTO`
  alone proves the non-deadline path (review condition 6). `requireRigReachable` stays (it is
  still the right guard against a down rig) but its rationale comment changes.
- `docs/INTEROP-QUIC.md`: the "TLS trust rejection surfaces as the connect deadline" trap is
  rewritten as resolved; add the 2026-08-28 Windows Server 2022 observation (self-signed cert,
  `.customRoots([leaf])` and `.insecureNoVerification` succeed, `.system` rejected with `-9808`,
  1.1 GB read at ~34 MB/s vs ~38 MB/s TCP, identical MD5).

## Risks / Trade-offs

- [A future Network.framework release reports a genuinely retryable condition as `.waiting(.tls)`]
  → Callers already own retry at the connect level; a prompt `EPROTO` is strictly more actionable
  than a 30 s `ETIMEDOUT`. Documented in the spec as the deliberate trade.
- [A caller relied on `ETIMEDOUT` for trust rejections] → It was documented as a limitation, never
  as a contract; the proposal marks the behavioral change and the release note should mention it.
- [`.waiting(.tls)` in the commit-to-start window] → Handled by reusing `handleFailed` (D2), which
  already parks the loss; covered by a dedicated test.
- [`NSUnderlyingErrorKey` payload makes `POSIXError` `userInfo` non-`Sendable`-friendly] →
  `POSIXError` already carries `[String: Any]` `userInfo` (description today); no new constraint.

## Migration Plan

No migration: internal seam change plus error-payload enrichment. Rollback is reverting the
commit; no persisted state or public signatures change.
