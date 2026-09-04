---
name: inbound-profiling-review
description: add-inbound-profiling-baseline (issue #44) review verdict, plus durable os_signpost and inbound-hop facts verified against the code
metadata:
  type: project
---

`add-inbound-profiling-baseline` (issue #44, target 6.0.0-rc4) reviewed 2026-09-04 →
**APPROVED WITH CONDITIONS** (11 conditions) → re-gate 1 revision required (teardown inside the
flush error path; unsound pump-hop byte-count pairing) → **re-gate 2 APPROVED** 2026-09-04. It is the measurement gate for
#45 (inbound push-conversion) and #46 (`maximumReceiveLength` sweep).

**Why:** PR #43 deferred #45/#46 because the only traces were Debug debugger launches with
~76% Instruments overhead. This change adds `os_signpost` on the seam inbound path, a
`docs/PROFILING.md` capture procedure (Apple TV primary), and `scripts/profile-summary.sh`.

**How to apply:** durable facts verified in this review, reusable for any future
instrumentation or inbound-path work:

- **The inbound hop chain is four executors**: `InboundBufferingHandler.channelRead` (NIO EL,
  `TCPTransportApple.swift`) → resumes `receive()` → inbound pump `Task` (cooperative pool) →
  `TransportBridge.appendInbound` → `consumeInboundReadySignal` → `eventLoopQueue`. Anything
  instrumented at `appendInbound` starts **after** the cooperative-pool hop that #45 removes.
  Do not claim a dispatch interval anchored there measures that hop.
- **Swift varargs defeat "free when idle"**: `os_signpost(…, "%d", x)` builds the
  `[any CVarArg]` array at the call site, before the callee's enablement check. Any hot-path
  emit must be preceded by `guard log.signpostsEnabled else { return }`.
- **Availability/Sendable are non-issues**: `os_signpost` / `OSSignpostID` /
  `OSLog.signpostsEnabled` are macOS 10.14 / iOS 12 / tvOS 12 / watchOS 5 — below every
  `Package.swift` floor. SDK has `OSLog: @unchecked Sendable`, `OSSignpostID: Sendable`.
  `OSSignposter` needs iOS 15/macOS 12/tvOS 15, i.e. a floor bump.
- **`servicePending` pairing**: transitions false→true only in `consumeInboundReadySignal`,
  true→false only in `beginServicePass` and `teardownSeam`, all under `serviceFlagLock` —
  so exactly one clear site sees the armed flag. `serviceContextForSeam` has one call site
  (`Context.swift:1672`) and is non-reentrant.
- **`InboundBufferingHandler.receive()` coalesces**: `channelRead` appends to `buffer` when no
  continuation is parked, and `receive()`'s fast path returns the *whole* accumulated buffer as
  one `Data`. So N network chunks collapse into 1 bridge chunk exactly when the cooperative pool
  is backed up. Never assume a 1:1 `channelRead` → `appendInbound` cardinality; pair by FIFO
  order + byte-sum, not by byte-count equality. The handler's invariant — a non-empty `buffer`
  and a parked `waitingContinuation` are mutually exclusive — means every delivered `Data` is a
  contiguous prefix of the read stream, so FIFO byte-sum pairing is exact by construction.
- **`serviceContextForSeam` has two teardown paths**: its own `smb2_service < 0` branch, and
  `flushOutboundForSeam`'s `smb2_service(POLLOUT) < 0` branch (`Context.swift:1851-1855`), which
  tears down and destroys the context *inside* the caller and returns normally. Any "before
  teardown" ordering in `serviceContextForSeam` must account for both.
- **Repo has no `CHANGELOG.md`**; release notes live on the GitHub release / issue.
- Trace bundles `../RandomPlayer/*.trace` are outside this repo and gitignored in the consumer
  repo — never make them a CI-reproducible fixture. `test-fixtures/` is the repo-local home.

See also [[review-gate-recurring-findings]], [[quic-release-track]].
