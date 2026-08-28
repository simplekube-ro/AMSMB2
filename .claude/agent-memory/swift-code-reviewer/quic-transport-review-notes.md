# QUIC transport — review history

## `quic-fail-fast-on-tls-rejection` (2026-08-28) — APPROVED
Added `QUICWaitClass { transient, fatal }`, `QUICConnectionState.waiting(POSIXError, QUICWaitClass)`,
`handleState` routes `.fatal` into `handleFailed`, `mapState` maps `NWError.tls` → `.fatal`,
`asQUICPOSIXError` puts the Security `OSStatus` under `NSUnderlyingErrorKey`
(`NSOSStatusErrorDomain`). `mapState` and `asQUICPOSIXError` relaxed `private`/`fileprivate` →
`internal` for direct testing instead of adding a test-only seam symbol.

**Verified sound, with the reasoning worth reusing:**
- No double-claim on repeated `.waiting(.tls)` (Network.framework does re-emit): the second
  delivery finds `connectState == .failed` (set unconditionally at the top of
  `consumeLossClaimLocked`) and hits `.ignore`. Notably this also prevents a **second park** into
  `pendingLoss`, which would have leaked a continuation.
- Fatal wait in the commit-to-start window parks correctly and the deadline is cancelled exactly
  once by the post-`start()` handoff.
- Post-ready fatal `.waiting` → abnormal loss (D8). Real-world exposure is nil: post-`ready`
  `.waiting` in practice carries `.posix` (path loss), which stays transient.
- Record-then-claim is two separate lock acquisitions, but the non-atomicity is benign: it only
  decides whether the deadline's `ETIMEDOUT` message carries the TLS status (design D4 wants it).

**Nits raised and applied in the same review cycle:** `mapState` now maps once via
`let waitClass: QUICWaitClass = if case .tls = error { .fatal } else { .transient }` (SE-0380
if-expression with `if case` — compiles fine); `handleState` dispatches with an exhaustive
`switch waitClass` so production no longer leans on payload-free enums' implicit `Equatable`;
`testFatalWaitingAfterDeadlineIsNoOp`'s doc comment now names `CheckedContinuation`'s
double-resume trap as the load-bearing check, since its explicit assertions pass on pre-change
code too. Final verdict: APPROVE.
