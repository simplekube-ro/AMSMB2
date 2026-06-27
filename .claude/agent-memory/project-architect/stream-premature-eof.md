---
name: AsyncInputStream premature-EOF fix (fix-stream-premature-eof)
description: Root cause + architect gate guardrails for the streamed-upload 5 MiB truncation
type: project
---

Streamed uploads via `AsyncInputStream` (AMSMB2/Stream.swift) truncated at exactly 5242880 bytes.

**Root cause:** `read(_:maxLength:)` set `_streamStatus = .atEnd` on the post-copy transition
`bufferOffset == buffer.count` without checking producer exhaustion — a transient drain (consumer
out-pacing the prefetcher paused at highWaterMark) was mis-reported as EOF; the consumer saw `0` and
broke. Exposed by the Apple seam (faster async send drains the prefetch cushion the legacy socket
masked).

**Fix (architect-approved, approach=revised):** `producerFinished` flag set under `bufferLock` only
on natural iterator exhaustion; gate `.atEnd` on it; `read()` returns `-1` (would-block) when drained
but producer still running; async consumer `write(client:from:toPath:)` retries on would-block via
`await Task.yield()`. Confined to Stream.swift + that one consumer. No seam/Context change.

**Why:** minimal, preserves InputStream abstraction, no lock across await. Rejected: sync-blocking
read() (sync-over-async, starves cooperative pool); symmetric dataAvailableContinuation (cleaner on
liveness but adds a 2nd continuation + teardown — deferred); bypassing InputStream (larger refactor).

**How to apply / guardrails baked into design.md (D-5/D-6) + tasks + spec:**
- **G1 (blocking):** producer `catch` MUST also set `_streamError = error`. `_streamError` was NEVER
  assigned anywhere, so `streamError` was always nil and real errors were dropped to a generic EIO.
- **G2:** consumer discriminates the error case on `streamStatus == .error`, throws
  `streamError ?? POSIXError(.EIO)`.
- **G3:** would-block is `.open`/`.reading` + `streamError == nil` ONLY; `-1` with
  `.closed`/`.notOpen`/`.opening` is terminal (break, never retry) — else a closed stream hangs.
  Spec prose "not .error" was too broad; tightened.
- **G4 (dead-code):** `InputStream.readData(maxLength:)` has exactly one call site (the consumer);
  after rewrite it must be deleted same-task or replaced by a single-call-site tri-state helper.
- **G5 (confinement):** the private consumer only ever receives an `AsyncInputStream` (sole ctor at
  AMSMB2.swift:1210; no raw-InputStream overload forwards here) — no arbitrary-InputStream hazard.
- Acceptance bar: FULL integration suite through the seam (SMB_TRANSPORT=seam) with ZERO failures
  AND testStreamUploadDownload x8 random sizes (>5 MiB) — grep for "failed (", don't trust exit code.

**FINAL REVIEW 2026-06-27 — SIGNOFF: APPROVED (verified first-hand).** Build clean; 4 AsyncInputStream
unit tests green; FULL seam suite 148 tests / 1 skipped / 0 failures; stream test x8 all passed,
6 runs >5 MiB (8.1/15.2/11.1/5.8/11.7/5.4 MB) none truncated — last progress == size (e.g. 8920685
of 8920685) and contentsEqual byte-equal held. `readData(maxLength:)` deleted, no orphan refs.
Linux path intact (write loop + read() are platform-agnostic; only the connect transportKind #if is
seam-scoped). Gotcha re-confirmed: the `uploaded: 5242880 of N` log line is the FIRST progress
callback at the prefetch-pump boundary, NOT truncation — pass/fail is line 394 contentsEqual.
NOTE: tasks C4.1/C4.2 (swift-code-reviewer pass) still unchecked — process step, not a code defect.
