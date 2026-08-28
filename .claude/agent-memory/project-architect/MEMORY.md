# Project Architect Memory

## OpenSpec workflow & review-gate precedent
- [OpenSpec review-gate verdict matching](openspec-review-gate-verdicts.md) — hook match is textual; quoting the revision verdict in findings blocks apply even under an APPROVED verdict.
- [Re-gate precedent: fix-swift6-concurrency scope expansions](regate-fix-swift6-concurrency.md) — how scope creep during apply was ruled on.
- [quic-transport review history](quic-transport-review.md) — add-quic-transport gate history + verified code facts; 9th review 2026-07-25 APPROVED.
- [tcp-one-shot-connect review](tcp-one-shot-connect-review.md) — APPROVED WITH CONDITIONS 2026-07-25; earlier APPROVED retracted same day; Network.framework test-timing gotcha.

## Transport seam
- [Seam connect-ordering fix decision](seam-connect-ordering.md) — root cause + decision for fix-seam-connect-ordering.
- [Transport rollout T9 Apple/Linux split](transport-rollout-t9-split.md) — legacy DispatchSource path is unguarded; T9 must guard-not-delete for Linux.

## C interop & concurrency invariants
- [CBData retain/release ownership contract](cbdata-ownership-contract.md) — exactly-once balance rule for the per-op passRetained CBData.
- [Swift 6 strict concurrency in Context.swift](swift6-strict-concurrency-context.md) — Linux hard-errors where macOS warns; sanctioned fix patterns.

## Known bug classes
- [AsyncInputStream premature-EOF fix](stream-premature-eof.md) — root cause + gate guardrails for the 5 MiB streamed-upload truncation.
