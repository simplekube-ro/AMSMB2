# Project Architect Memory

## How to work here
- [review-gate-recurring-findings.md](review-gate-recurring-findings.md) — the five gap classes to check first on any `/opsx:propose` review.
- [openspec-review-gate-verdicts.md](openspec-review-gate-verdicts.md) — how the review-gate hook parses the proposal.md `## Review` section.

## Project context
- [quic-release-track.md](quic-release-track.md) — SMB-over-QUIC ships as a numbered rc series (rc2 = #59, rc3 = #61); consumer RandomPlayer; interop rigs + env vars.
- [transport-rollout-t9-split.md](transport-rollout-t9-split.md) — legacy DispatchSource path must be guarded, not deleted, for Linux.

## Change reviews
- [disconnect-context-reclaim.md](disconnect-context-reclaim.md) — issue #49 review verdict; CBData→client retain cycle, stranded TransportBridge retain, fail-before-destroy invariant.
- [quic-transport-review.md](quic-transport-review.md) — add-quic-transport gate history and verified code facts about the connect state machine.
- [tcp-one-shot-connect-review.md](tcp-one-shot-connect-review.md) — fix-tcp-one-shot-connect verdict history; Network.framework test-timing gotcha.
- [seam-connect-ordering.md](seam-connect-ordering.md) — fix-seam-connect-ordering root cause and decision.
- [stream-premature-eof.md](stream-premature-eof.md) — AsyncInputStream premature-EOF fix guardrails.
- [inbound-profiling-review.md](inbound-profiling-review.md) — issue #44 profiling gate verdict; inbound hop chain, os_signpost vararg cost, availability facts.
- [regate-fix-swift6-concurrency.md](regate-fix-swift6-concurrency.md) — re-gate precedent for scope expansions.

## Invariants
- [cbdata-ownership-contract.md](cbdata-ownership-contract.md) — exactly-once CBData retain/release balance with libsmb2.
- [swift6-strict-concurrency-context.md](swift6-strict-concurrency-context.md) — Linux swift:6.1 hard-errors on @Sendable captures macOS only warns on.
