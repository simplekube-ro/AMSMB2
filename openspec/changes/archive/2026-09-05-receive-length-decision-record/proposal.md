## Why

[Issue #46](https://github.com/simplekube-ro/AMSMB2/issues/46) asks for a measured decision on
`NIOTSChannelOptions.maximumReceiveLength` (256 KB since PR #43, at
`AMSMB2/TCPTransportApple.swift:251`), taken against the rc5 After numbers in
`docs/PROFILING.md`. A device sweep was planned first (change `receive-length-sweep-harness`,
superseded by this one); its architect review pointed out that since the inbound
push-conversion (#45) every `TransportRead` is exactly one `InboundChunk`, so the cap is the
ceiling of the chunk-size distribution the three rc5 bundles already hold, and those bundles
bound the effect of any cap in the sweep range in both directions. The pre-check on them
(2026-09-05) found the cap reached by 0.25–0.43 % of chunks per run, so raising it can remove
at most ~1.6 ms of the 25 µs-per-chunk chain over a 5.8–11.3 s fill, while lowering it costs
0.5–12 % more chunks. An effect that small sits inside the run-to-run spread the After section
already records (dispatch median 0.013–0.014 ms across five runs, pass p95 0.032–0.040 ms,
throughput link-bound), so no sweep on this workload could resolve it. The decision can be
recorded now.

## What Changes

- **A chunk-ceiling line in `scripts/profile-summary.sh`**: after the `InboundChunk` size
  line, the count and share of chunks at the maximum observed chunk size (the cap, when it
  binds) with their byte share, plus the share of chunks and bytes at or above 64 KB,
  128 KB, 256 KB, 512 KB and 1 MB. This is the saturation metric that tells "the cap never
  binds" from "no difference", so any future capture can be read against #46 without an
  ad-hoc script; it reads the receive length only where the coalescing ratio is 1.00, which the
  line's documentation states. The four fixtures' `expected.txt` are updated, and one new
  fixture (`ceiling-export`) is added because the three existing ones top out at 1 500-byte
  chunks and would leave the threshold shares covered only at zero. Output otherwise unchanged.
- **A dated "Receive length (#46)" subsection in `docs/PROFILING.md`**: the per-run ceiling
  table from the three rc5 bundles computed by the updated script, the reading (what raising
  and lowering the cap could change, in chunks and in chain time), the decision to keep 256 KB,
  and the rule for revisiting it (a capture whose at-cap share exceeds a stated threshold).
- **No change to the transport.** The literal stays `1 << 18`; its comment gains one sentence
  pointing at the subsection so the next reader does not re-open the question.
- Closes #46 on merge.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `inbound-profiling`: the **Trace summary tooling** requirement is modified to include the
  chunk-ceiling line (a MODIFIED delta, since the requirement enumerates the script's output);
  a new requirement records the receive-length decision in the profiling document. The
  document's Metrics-table row for the ceiling is a refinement of the *inbound chunk-size
  distribution* metric the capture-procedure requirement already enumerates, so that
  requirement is not modified.

## Impact

- `scripts/profile-summary.sh` (one new output line), the three existing `expected.txt`
  fixtures plus one new fixture directory under `test-fixtures/profiling/`, `docs/PROFILING.md`
  (the new subsection, the Metrics row, a fourth fixture `diff`), one comment line in
  `AMSMB2/TCPTransportApple.swift`. No library code, no API, no behaviour change.
- The bundles the record is computed from are the gitignored rc5 captures in
  `../RandomPlayer/profiling/`; the subsection carries every number, so the record stands
  without them.

## Review

### Round 1 (2026-09-05) — APPROVED WITH CONDITIONS

The re-scope is the right call and the core reasoning is sound. Verified against the code: since
#45, `TCPTransportAppleInboundHandler.channelRead` emits one `TransportRead` and forwards exactly
that `ByteBuffer` as one `InboundChunk` (`AMSMB2/TCPTransportApple.swift:615-627`, zero-length
reads returned before the signpost), and `docs/PROFILING.md` records the coalescing ratio as 1.00
by construction in all three rc5 runs. So `maximumReceiveLength` *is* the ceiling of the
`InboundChunk` distribution on those bundles, raising the cap can only merge at-cap chunks and
lowering it can only split over-cap chunks, and the three bundles bound the whole achievable
effect of any cap in [64 KB, 1 MB]. The 25 µs-per-chunk chain the reading leans on is the
documented After figure (`docs/PROFILING.md`, After delta table). The design's own arithmetic is
internally consistent (65/15 142 = 0.429 %, 65 × 262144 / 399 MB = 4.27 %, and the +133 / +482
split counts follow from the threshold shares). No library behaviour changes; no thread-safety, C
interop, platform, LGPL or public-API surface is touched.

Eight conditions; **1, 2, 3, 4 and 8 have been applied directly to design.md, spec.md, tasks.md
and this proposal** — the remaining ones are implementation obligations carried in tasks.

1. **Spec delta type — the ceiling metric is a MODIFIED delta, not an ADDED requirement.**
   *Applied.* The existing **Trace summary tooling** requirement enumerates the script's output
   exhaustively; a second requirement adding one more line to the same script leaves that
   enumeration stale and splits the script's contract across two places. `spec.md` now carries the
   whole existing requirement block under `## MODIFIED Requirements` with the ceiling paragraph
   woven in after the first paragraph and the two ceiling scenarios appended, and keeps
   **Receive-length decision record** under `## ADDED Requirements` (it governs document content
   and the transport comment, which no existing requirement covers). Ruling on the adjacent
   question: adding the ceiling row to the document's Metrics table does **not** need a delta on
   **Release-build on-device capture procedure** — that requirement already enumerates "inbound
   chunk-size distribution" as a metric to record, and the ceiling is a refinement of it. Recorded
   in proposal.md so the reading is on the record rather than implicit.

2. **The fixtures give the threshold shares zero coverage.** *Applied.* All three committed
   fixtures top out at 1 500-byte chunks, so every one of the five threshold shares would be
   `0.000% / 0.00%` in every `expected.txt`: a wrong comparison operator, a wrong denominator, or
   a swapped chunk/byte share would diff clean and ship. D2 now adds a fourth fixture,
   `ceiling-export`, whose chunk sizes straddle the thresholds (with two chunks at the maximum, so
   the at-max count is not the degenerate 1), with its own `expected.txt` and a fourth `diff`
   command in the document; the fixture scenario in the spec requires non-zero shares on at least
   three of the five thresholds. Enlarging the existing fixtures was rejected as churn.

3. **The ceiling reads the receive length only where the coalescing ratio is 1.00.** *Applied.*
   The metric under #46 is the *transport read* size; `InboundChunk` is a proxy that holds only
   post-#45 on TCP. On a pre-#45 bundle read with `--pairing global`, or on a QUIC capture (the
   shape of the `no-transport-read-export` fixture), the maximum is a coalesced maximum and reads
   the cap only by accident — and the script will happily print a ceiling line for it. The caveat
   is now in the requirement, in D1, and in tasks 2.1 and 4.1 (script header comment and Metrics
   row). Computing the ceiling from `TransportRead` instead was considered and rejected in D1,
   with the reason recorded.

4. **Task 3.1 presupposed the number it exists to verify.** *Applied.* It read "verify the ceiling
   lines report 65 chunks … with the shares of the design table", which turns an independent
   recomputation into a confirmation and would push an implementer to force agreement. Rewritten:
   record what the script prints verbatim, compare against the Context table, and if any run
   disagrees correct design.md and the record rather than the output. Task 3.1 also now checks
   each run's coalescing ratio is 1.00, which is condition 3's precondition for reading the line
   at all.

5. **The identical 65 must be a stated caveat in the record, not a footnote.** *Applied to
   design.md Context; carry into `docs/PROFILING.md` in task 4.1.* An exact invariant across three
   runs that differ in length, byte total and p95 is the signature of a systematic artefact, not
   of a coincidence, and a record that reports it without saying so invites the next reader to
   treat it as a measured constant. The Context now says why it does not move the decision: if the
   65 are real saturation, raising the cap removes at most those 65; if some returned exactly the
   cap without the socket being full, the at-cap count *overstates* what raising could remove, so
   the bound only gets more conservative. The record must carry the same two sentences.

6. **Label the lowering figures as derived.** *Applied to design D3; carry into the record.* The
   "+465 / +1 819" rows are not measurements — they are each over-cap chunk split at a
   hypothetical cap. A real capture at 64 KB would also re-clock the receive loop, so the split is
   a first-order estimate. D3 item 3 now says so, requires the figures to be reported per run
   (never averaged across the documented run-1 outlier), and adds the point that closes the other
   direction of the sweep outright: `maximumReceiveLength` caps what a completion returns and
   pre-allocates nothing, so lowering it has a cost and no identified benefit.

7. **The 5 % revisit threshold is defensible, but not for the stated reason.** *Applied to D3;
   the arithmetic must appear in the record.* D3 justified 5 % as "the point where merging could
   remove a visible share of the per-chunk chain". It is not: at a 5 % at-cap share, run 3's
   26 494 chunks put ~1 325 at the cap, and merging every one saves at most ~33 ms over a ~10 s
   fill — under a tenth of what #45 removed (~0.4 s). A break-even-with-effort threshold would be
   tens of percent. 5 % is sound as a **shape-change tripwire** — an order of magnitude above
   every rc5 run — and D3 now says that, with the arithmetic, so the next reader can move the
   number instead of inheriting an unexplained one. The second trigger
   (`minimumIncompleteReceiveLength` raised above 1) is correct and is the premise of the whole
   reading; keep it.

8. **Two wording defects that would mislead the implementer.** *Applied.* (a) The Why claimed the
   effect is "below the noise floor the procedure documents" — `docs/PROFILING.md` documents no
   noise floor; it documents a run-to-run spread. Replaced with the concrete spread (dispatch
   median 0.013–0.014 ms, pass p95 0.032–0.040 ms, throughput link-bound). This also keeps the
   change clear of the superseded review's lesson about sourcing thresholds from another
   workload's spread. (b) D1 said the ceiling percentages use "the same rounding rules as the rest
   of the script" and then specified three and two decimals — the script's only other percentage
   is the per-thread share at one decimal. Reworded to say the finer precision is deliberate, with
   the reason.

Two further items for the implementer, not conditions: the record should state plainly that this
is a decision *not* to change the transport, so that "Using the baseline" step 3's before/after
delta requirement is not read as having been skipped (now required by the spec and D3 item 4 and
carried in task 4.1); and the `n/a` branch stays an ad-hoc check rather than a fifth fixture, with
task 2.2 requiring the exact command and printed line to be recorded so the check is reproducible.

Quality gates: no public interface modified; no new abstraction; no dependency; thread-safety and
C-interop boundaries untouched (the only source edit is a comment); Linux unaffected (the script
is developer tooling and the transport line is inside `#if canImport(Network)`); LGPL posture
unchanged. Second-order: `scripts/profile-summary.sh` output is pinned by fixture `diff`s and its
five signpost names by `SignpostContractTests`, both covered by tasks 2.1/2.3; third-order: the
document's fixture `diff` list and Metrics table are the only other consumers of the script's
output, and tasks 1.1 and 4.1 update both.

### Context from the superseded change

`receive-length-sweep-harness` (Round 1, 2026-09-05, 12 findings, revision required) proposed a
self-driving tvOS harness and sweep and did not pass its gate. Finding 1 of that review is the
pre-check this change is built on; findings 2–12 concerned the harness and no longer apply. The
user chose to re-scope to this record rather than revise the harness.
