# Project Architect Memory

## Transport rollout (add-pluggable-tcp-transport)
- transport-rollout-t9-split.md — T9 must GUARD-not-delete the legacy DispatchSource path (Linux keeps it); legacy code is currently unguarded; over-deletion breaks Linux invisibly.
- seam-connect-ordering.md — root cause of broken Apple seam (detached connect + premature `ext.connect` return-0) and architect decision: Approach A (eager connect), Apple seam-only, with binding teardown/encapsulation mandates.

## Concurrency / Swift 6
- swift6-strict-concurrency-context.md — swift:6.1 Linux hard-errors on @Sendable captures macOS only warns on; local cbPtr construction + nonisolated(unsafe) for must-cross handler & queueKey. FINAL REVIEW 2026-06-27: 5 fixes correct & race-safe (retain/release 1:1, no UAF/double-free); confirmed FIRST-HAND macOS Context.swift recompile clean + make linuxtest exit 0 (114 tests/50 skip/0 fail). C2b test-portability fixes (2 test files) accepted into this change. proposal.md Non-Goal still wrongly says "confined to Context.swift" — must reconcile before archive.

## Stream / upload
- stream-premature-eof.md — AsyncInputStream 5 MiB upload truncation (`.atEnd` on transient drain). Fix = producerFinished + would-block `-1` + consumer Task.yield retry. Gate guardrails: G1 set `_streamError` (never assigned!), G2 error on `streamStatus==.error`, G3 narrow would-block (.open/.reading only), G4 delete orphaned readData, G5 consumer only sees AsyncInputStream.
