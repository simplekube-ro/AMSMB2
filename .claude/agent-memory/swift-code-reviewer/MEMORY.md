# swift-code-reviewer — AMSMB2 institutional notes

## Verified project conventions (confirmed by review)
- Errors are `POSIXError` only. `POSIXError(_:description:)` and `POSIXError(_:userInfo:)` both
  live in `AMSMB2/Extensions.swift` (~line 70). No custom Error types anywhere.
- Line width: `.swiftformat --maxwidth 132`, `.swift-format lineLength 100`. In practice the
  codebase holds to **100**; flag added lines over 100.
- Build/test must use `--disable-sandbox`. Full suite is ~285 tests, ~67 skipped (integration,
  `SMB_SERVER`/`SMB_QUIC_SERVER` unset). Zero warnings is the standing bar.
- `swift build` caches aggressively — `touch` the changed files before rebuilding if you need to
  see warnings.

## QUIC transport (`AMSMB2/QUICTransportApple.swift`) — the claim machinery
This file is the most intricate in the repo. Key invariants to re-verify on ANY change:
- `resolveConnect(_:)` is the **single atomic claim point**; it guards on
  `case .connecting(let continuation)`. Every completion path (`.ready`, `.failed`, task cancel,
  `close()`, deadline) funnels through it. Losers get `nil` and perform **no** side effects.
- `consumeLossClaimLocked` sets `connectState = .failed` **first, unconditionally**, before its
  `startPhase` switch. This is what makes repeated terminal events idempotent: a second delivery
  finds `.failed` and hits `.ignore`. Do not let anyone reorder that assignment.
- `startPhase` three-way handoff: `.notStarted` → forbid start (nothing to cancel);
  `.starting` → **park** in `pendingLoss`, return `nil`, and `resolveConnect` returns *before*
  `deadline.cancel()` — the post-`start()` handoff does the single deadline-cancel + driver-cancel
  + resume; `.started`/`.forbidden` → cancel the driver inline.
  A connection must never be cancelled before its `start()` side effect.
- `handleFailed` reads state under the lock, releases it, then calls `resolveConnect` which
  re-takes it. Two callers can both pass the first check — safe **only** because `resolveConnect`
  re-guards. Preserve that second guard.
- Seam: `QUICConnectionState` is driver-neutral (no Network.framework types cross it); tests inject
  `ScriptedQUICDriver` / `GatedStartDriver` / `GatedCancelDriver` + `ManualDeadlineScheduler`.

## Recurring review checks that have paid off here
- **Test-only production symbols**: CLAUDE.md's dead-code gate says every new type needs a call
  site outside its definition file. The QUIC seam legitimately keeps producer + consumer in one
  file, so judge by *intent* (would removing it break production?) not by the letter.
- **Unbounded `await parked`** in post-ready abnormal-loss tests (`async let parked` +
  `await parked`) is the established pattern in `QUICTransportAppleTests.swift`. A regression
  hangs rather than fails. Bounded helpers exist: `waitUntil` (2000 × 1 ms), `expectPromptPOSIX`,
  `launchConnect`, `reap`, `ErrorBox`. Prefer them for new connect-phase tests.
- **Double-resume is self-detecting**: continuations are `CheckedContinuation`, so a second resume
  traps the process. Tests asserting "no double resume" do get real signal from that.
- **Error `userInfo` survives to the public API**: `Context.mapTransportConnectError`
  (`AMSMB2/Context.swift` ~1417) passes `POSIXError`/`CancellationError` through **verbatim** and
  only wraps foreign errors. So transport-level `userInfo` (e.g. `NSUnderlyingErrorKey`) does
  reach `SMB2Manager.connectShare` callers.

## Detail files
- `quic-transport-review-notes.md` — per-change findings history for the QUIC seam.
