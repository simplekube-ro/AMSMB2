## Why

`scripts/profile-summary.sh` derives the pump-hop latency by pairing `TransportRead` events
to `InboundChunk` events in one global FIFO across the whole capture: pop reads in timestamp
order until their bytes sum to the chunk's size. That was the only possible pairing before the
inbound push-conversion (#45), when the chunk was appended from a cooperative-pool pump task on
a thread other than the read's. It mispairs whenever two connections' reads interleave —
RandomPlayer fills over 9–13 SMB connections at once, each on its own NIOTS event-loop thread,
so a read from connection B landing between connection A's read and A's chunk is consumed by
A's chunk. On the rc5 After capture (`docs/PROFILING.md`, PR #68) the script reported 155 / 1 / 0
pairing errors across the three runs, every one of them an overshoot/underflow *pair* that is
not real: the byte totals of the two event kinds differ only by the attach carry-over, so the
events are all there and only the pairing is wrong. The hop row is therefore only trustworthy on
a run that happens to report zero errors, and #46 (the `maximumReceiveLength` sweep) is about to
read that row against the rc5 numbers. This is [issue #69](https://github.com/simplekube-ro/AMSMB2/issues/69).

Since #45 each `TransportRead` and its `InboundChunk` are emitted back-to-back on the same
thread (the transport forwards the read into the bridge inside the same callback — see the
`InboundSignposts.chunk` doc comment), so keyed by the `thread` column of the `os-signpost`
export the pairing is a strict per-thread FIFO with no byte-sum search. Recomputed that way for
the three rc5 runs: 15141 / 19708 / 26494 pairs, at most one chunk-without-read per run (the
attach carry-over), and the same latency percentiles the script already prints for the clean run.

## What Changes

- **Per-thread pairing becomes the script's default.** `TransportRead` and `InboundChunk`
  events are grouped by the thread that emitted them and paired within each thread in timestamp
  order: a chunk pairs with the read pending on its thread when the byte counts are equal. Byte
  equality stays as the assertion; a mismatch is still a pairing error. Two situations that the
  global FIFO could only report as errors are now counted for what they are: a **chunk without
  a read** pending on its thread (the attach carry-over whose read preceded the recording, a
  read signpost the recorder dropped, or a chunk from the QUIC transport, which emits no
  `TransportRead`), and a **read without a chunk** (the read that races bridge teardown,
  documented in the Metrics table). Both are counted and printed next to the pairing line, not
  reported as errors.
- **The pairing mode and the number of delivery threads are printed.** A `pairing:` line names
  the mode used and, in per-thread mode, the number of distinct threads that emitted
  `TransportRead` or `InboundChunk` — the "connections" column the After table in
  `docs/PROFILING.md` had to be computed by hand, and context for the per-thread CPU table and
  for #46.
- **The global FIFO stays available behind an explicit flag** (`--pairing global`) for pre-#45
  bundles (the rc4 Baseline). **Deviation from the issue's proposal, stated for review:** the
  issue asked for an automatic fallback "when a thread's `InboundChunk` events have no
  `TransportRead` events on the same thread". That detector cannot tell the two worlds apart in
  practice: the After section's own reading records that in the Baseline "12 of the 13 threads
  that appended chunks were also threads that read from the network" (the cooperative pool and
  the NIOTS event loops are both Dispatch worker threads), so a pre-#45 capture *does* have reads
  on its chunk threads and the auto-detector would pair it per thread and print garbage with a
  clean conscience. Any heuristic keyed on error counts instead is a threshold on data the
  operator is trying to measure. The mode is therefore an explicit input, printed in the output
  so a summary can never be misread, and the doc states which bundles need which mode.
- **The reads-per-chunk distribution is printed only in global mode.** In per-thread mode every
  pair is one read to one chunk by construction, so the line would carry no information; the
  coalescing ratio line (a pure count ratio) stays in both modes.
- **Fixtures.** The existing `test-fixtures/profiling/sample-export` is a faithful pre-#45-shaped
  export (reads on the NIO thread, chunks on a pump thread, one coalesced group) and stays as
  the pinned fixture for global mode — its `expected.txt` gains only the `pairing:` line and the
  documented `diff` command gains `--pairing global`. A second hand-written fixture,
  `test-fixtures/profiling/per-thread-export`, is shaped like an rc5 capture — two delivery
  threads whose reads and chunks interleave in time (the case the global FIFO gets wrong), one
  attach carry-over chunk, one unpaired teardown-race read, and one byte mismatch — with its own
  `expected.txt` pinning per-thread mode, and a comment stating what the global FIFO would have
  reported for the same rows so the fixture demonstrates the defect it fixes. A third fixture,
  `test-fixtures/profiling/no-transport-read-export`, is that fixture without its
  `TransportRead` rows and pins the no-read shape (`pairing:` line plus `n/a`), which is what a
  QUIC capture produces.
- **`docs/PROFILING.md`:** the Metrics rows for the coalescing ratio and pump-hop latency
  describe the per-thread pairing, the chunk without a read and the read without a chunk; the Export section
  documents the `--pairing` flag, both fixtures and both `diff` commands; the After section's
  procedure note that says "keying the script's pairing by thread is a follow-up" becomes a
  statement of what the script now does, and the hand-computed "per-thread pairing" and
  "connections" rows of the After table are noted as what the script prints now; "Using the
  baseline" says the rc4 Baseline bundles need `--pairing global`.
- No library code changes. No public API change.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `inbound-profiling`: the **Trace summary tooling** requirement changes — the pump-hop latency
  derivation is keyed by thread by default, the chunk without a read and the read without a
  chunk are counted rather than reported as pairing errors, the pairing mode and the
  delivery-thread count are part of the output, and the global byte-sum FIFO is an explicitly
  selected mode for captures taken before the push-conversion. The scenario that pins the
  committed fixture gains the two new fixtures. The **Release-build on-device capture
  procedure** requirement changes where it defines the recorded pump-hop metric by the
  byte-sum algorithm and where it says how to run the script.

## Impact

- `scripts/profile-summary.sh` — argument parsing gains `--pairing per-thread|global` (default
  per-thread); the signpost parser reads the `thread` cell's `tid`; the pairing pass is
  restructured around a per-thread pending read; new `pairing:` output line; the
  reads-per-chunk line becomes global-mode only. The header comment's Conventions section is
  updated. Exit statuses and the `n/a` behaviour without `TransportRead` events are unchanged.
- `test-fixtures/profiling/sample-export/expected.txt` — one added line.
- **New** `test-fixtures/profiling/per-thread-export/{time-profile.xml,os-signpost.xml,expected.txt}`
  and `test-fixtures/profiling/no-transport-read-export/{time-profile.xml,os-signpost.xml,expected.txt}`.
- `docs/PROFILING.md` — Metrics table, Export and summarise, After procedure notes, Using the
  baseline. The instrument-filter block and the five signpost names are untouched, so
  `SignpostContractTests` is unaffected.
- `openspec/specs/inbound-profiling/spec.md` — via the delta at archive time.
- Consumers: #46 reads the hop row from the default mode; anyone re-summarising the rc4 Baseline
  bundles (kept locally, gitignored) must pass `--pairing global` and the doc says so.

## Review

### Round 1 (2026-09-05) — APPROVED WITH CONDITIONS

Reviewer: `project-architect`. Reviewed the four artifacts against `scripts/profile-summary.sh`,
`test-fixtures/profiling/sample-export/`, the main `inbound-profiling` spec, `docs/PROFILING.md`,
the emission sites in `Signposts.swift` / `TCPTransportApple.swift` / `TransportBridge.swift`
and the issue text; independently re-ran the pairing probe on `baseline-run1` and confirmed the
design's central empirical claim (9 of 9 chunk threads also emitted reads, so the issue's
auto-detector never fires on a pre-#45 bundle; per-thread on that bundle gives 6494 pairs / 9442
chunks without a read / 9443 reads without a chunk / 5183 mismatches; global gives 21119 pairs /
0 errors). Verdict on the algorithm, the deviation from the issue (D2) and the fixture decision
(D4): correct. Conditions were gaps in spec coverage and documentation consistency.

### Conditions and how they were addressed (2026-09-05, same day)

1. **Second MODIFIED requirement.** The main spec's "Release-build on-device capture procedure"
   pins the recorded pump-hop metric "from the first coalesced `TransportRead`" and "how to run
   the summary script"; both change. → The delta spec now carries a full MODIFIED copy of that
   requirement with the pump-hop clause restated as pairing-mode dependent and the script clause
   naming the mode a bundle's generation needs; all three of its scenarios copied verbatim.
2. **Pasted script-output blocks in `docs/PROFILING.md`.** The Baseline and After blocks are
   literal pre-#69 output and would no longer be reproducible from the doc's own command; the
   design's "comparable line for line" goal was false as written. → Goal reworded; D6 states both
   blocks are regenerated from the archived bundles with the new script (Baseline with
   `--pairing global`, After in default mode) and marked as such, with every line outside the
   pairing block required to be identical; tasks 3.1 / 3.2 save the outputs and 4.1 applies them.
3. **Mismatch message thread format.** D1 printed `0xTID` while D5 keyed by the decimal `tid`
   text. → D1 and D5 now use the existing `thread_label()` form (`NIO-SGLTN-1-#1 (0x101)`), the
   tuple carries tid and label, task 1.2 pins the label form in `expected.txt`.
4. **Fate of the chunk on a mismatch.** → D1 states the error consumes both the pending read and
   the chunk, and records the two bucket invariants (`pairs + chunks without a read + errors ==
   InboundChunk count`; `pairs + reads without a chunk + errors + zero-byte skipped ==
   TransportRead count`); the delta spec's mismatch scenario says the same.
5. **"Attach carry-over" overclaim.** `InboundChunk` is emitted for every transport while
   `TransportRead` is TCP-only, so on a capture with a QUIC connection every QUIC chunk has no
   read. → The count is labelled **chunk without a read** (and, symmetrically, **read without a
   chunk**) in the output, the design, the delta spec and the proposal; D1, D6 and the Metrics
   row list the three causes (attach carry-over, dropped read signpost, QUIC chunk) with their
   expected magnitudes.

Observations taken up: the bundle-dependent tasks in section 3 now say how to record them when
the bundles are absent (obs. 6); the no-`TransportRead` branch is pinned by a committed third
fixture instead of a throwaway copy (obs. 7); D4 timeline items 4 and 5 carry byte counts
(obs. 8). Observations 1–5 (D2 evidence, D4, D5 parsing, D1 emission contract, no other repo
files affected — no CHANGELOG, README and ARCHITECTURE reference the script generically,
`SignpostContractTests` unaffected) required no change.
