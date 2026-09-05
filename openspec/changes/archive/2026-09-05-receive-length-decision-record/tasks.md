## 1. Fixtures first (design D2) — Red

- [x] 1.1 Add the `test-fixtures/profiling/ceiling-export` fixture (minimal `time-profile.xml`
      plus an `os-signpost.xml` whose `InboundChunk` sizes straddle the thresholds: one below
      64 KB, one at each of 65536, 131072 and 262144, one between 262144 and 524288, and two equal
      to the maximum), in the same hand-written form as the existing fixtures, with an
      `expected.txt` for the full output; add its `diff` command next to the other three in
      `docs/PROFILING.md`
- [x] 1.2 Compute the ceiling line by hand for `per-thread-export`, `sample-export`,
      `no-transport-read-export` and `ceiling-export` from each fixture's `InboundChunk` sizes
      (count at max, shares to the stated decimals, the ten threshold shares) and insert it after
      the `InboundChunk` line in each `expected.txt`. Compute it by a method independent of the
      new script code — read the sizes out of each `os-signpost.xml` and do the arithmetic
      directly — and record the extracted size lists in the PR description so the expectation is
      auditable; verify all four `diff` commands now fail against the unchanged script and that
      the only differing line is the new one, and that on `ceiling-export` at least three of the
      five threshold shares are non-zero

## 2. Script (design D1) — Green

- [x] 2.1 Print the ceiling line in `scripts/profile-summary.sh` after the `InboundChunk` size
      line (`ceiling: n/a` when there are no chunks), and update the header comment's output
      description with the line, its rounding, and the caveat that the ceiling reads the receive
      length only where the coalescing ratio is 1.00; verify the four fixture `diff`s are empty,
      `shellcheck scripts/profile-summary.sh` is clean, and running a fixture twice gives
      identical output
- [x] 2.2 Check the `n/a` branch: copy `per-thread-export` to a temp dir, delete its
      `InboundChunk` rows, run the script on the copy, and record in this task the exact command
      and the `ceiling: n/a` line it printed, plus that it exited 0

      Done. The copy's interning was expanded first (the five `InboundChunk` rows include the one
      that *defines* the interned thread/subsystem/event-type ids every later row references, so
      deleting them as they stand would orphan those `ref`s), then every row whose
      `<signpost-name>` is `InboundChunk` was removed — 5 rows — into `/tmp/no-chunks-export`.
      Command:

      ```
      scripts/profile-summary.sh /tmp/no-chunks-export
      ```

      Printed (with the neighbouring lines for context), exit status 0:

      ```
        InboundChunk     count 0, bytes 0, size n/a
        InboundChunk     ceiling: n/a
      ```
- [x] 2.3 Run `swift test --disable-sandbox --filter SignpostContractTests` to verify the name
      pinning still passes

## 3. Real bundles (design D3)

- [x] 3.1 Run the updated script on `../RandomPlayer/profiling/rc5-run{1,2,3}.trace` and record
      verbatim what each ceiling line prints — do not assume the pre-check's numbers. Compare
      against the design's Context table (65 chunks at max size 262144; 0.429 % / 4.27 %,
      0.330 % / 4.69 %, 0.245 % / 3.47 %). If any run disagrees, the pre-check table is wrong:
      correct design.md's Context table and this change's numbers before writing the record, and
      note the discrepancy in the record. Also verify every other line still matches the After
      section of `docs/PROFILING.md` and that each run's coalescing ratio is 1.00 (without which
      the ceiling line does not read the receive length); save the three outputs for task 4.1

      Done, on the updated script in its default per-thread mode. The three ceiling lines,
      verbatim:

      ```
      run 1:   InboundChunk     ceiling: 65 chunks at the max size 262144 (0.429% of chunks, 4.27% of bytes); at or above 65536: 7.549% / 38.34%, 131072: 3.071% / 22.66%, 262144: 0.429% / 4.27%, 524288: 0.000% / 0.00%, 1048576: 0.000% / 0.00%
      run 2:   InboundChunk     ceiling: 65 chunks at the max size 262144 (0.330% of chunks, 4.69% of bytes); at or above 65536: 0.873% / 8.19%, 131072: 0.497% / 6.28%, 262144: 0.330% / 4.69%, 524288: 0.000% / 0.00%, 1048576: 0.000% / 0.00%
      run 3:   InboundChunk     ceiling: 65 chunks at the max size 262144 (0.245% of chunks, 3.47% of bytes); at or above 65536: 1.000% / 8.44%, 131072: 0.502% / 5.94%, 262144: 0.245% / 3.47%, 524288: 0.000% / 0.00%, 1048576: 0.000% / 0.00%
      ```

      Agreement with design.md's Context table is exact on every figure it states (65 chunks at
      262144; 0.429 % / 4.27 %, 0.330 % / 4.69 %, 0.245 % / 3.47 %; and, to the Context table's
      coarser rounding, the 128 KB and 64 KB rows: 3.071/22.66, 0.497/6.28, 0.502/5.94 and
      7.549/38.34, 0.873/8.19, 1.000/8.44). No correction to design.md was needed. Each run's
      coalescing ratio is 1.00 (15141/15142, 19708/19709, 26494/26494). Every other line of run 3
      is byte-identical to the block recorded in the After section of `docs/PROFILING.md` (the
      ceiling line is the only addition), and runs 1 and 2 match every figure the After section's
      spread table records for them. Outputs saved as `/tmp/rc5-run{1,2,3}.txt`.

      One prose figure elsewhere in the change is off, though not in the Context table: the Why
      and D3 item 2 describe "a 7–11 s fill". The measured active spans are 11.289 s (run 1),
      5.776 s (run 2) and 8.477 s (run 3), so the range is 5.8–11.3 s. The record states the
      measured spans; the ~1.6 ms bound is unaffected.

## 4. Record (design D3, D4)

- [x] 4.1 Add the dated "Receive length (#46)" subsection to `docs/PROFILING.md` after the After
      section, following D3's five-item order: the capture set; the per-run ceiling table from
      task 3.1; the reading, with each raising/lowering figure marked measured or derived and its
      derivation stated; the explicit statement that this is a decision *not* to change the
      transport, so the "Using the baseline" delta rule has nothing to apply to; the caveat that
      the identical 65 across three runs of different length is unexplained and why the bound
      holds either way; the decision to keep `1 << 18`; and the revisit rule with the arithmetic
      that sets the 5 % threshold. Add the ceiling line to the Metrics table — as a refinement of
      the existing inbound chunk-size distribution row, carrying the coalescing-ratio caveat — and
      mention it in "Using the baseline"; verify every number in the decision appears in one of
      the three saved outputs or is labelled as derived from them
- [x] 4.2 Append one sentence to the comment on `NIOTSChannelOptions.maximumReceiveLength` in
      `AMSMB2/TCPTransportApple.swift` naming the subsection; verify `swift build --disable-sandbox`
      succeeds and `git diff --stat -- AMSMB2/` shows only comment lines
- [x] 4.3 Run `swift test --disable-sandbox` and the four fixture diffs; run `/opsx:verify`


## Notes for the PR

The `InboundChunk` size lists behind every expectation in this change, extracted from each
`os-signpost.xml` directly (a standalone reader, not the new script code) so the hand-computed
ceiling lines are auditable:

| Fixture | Chunk sizes | Bytes | Ceiling |
|---|---|---|---|
| `per-thread-export` | 1000, 500, 1500, 900, 700 | 4600 | 1 at max 1500 = 20.000% / 32.61%; all five thresholds 0.000% / 0.00% |
| `sample-export` | 1000, 2000, 3000, 1500, 72 | 7572 | 1 at max 3000 = 20.000% / 39.62%; all five thresholds 0.000% / 0.00% |
| `no-transport-read-export` | 1000, 500, 1500, 900, 700 | 4600 | 1 at max 1500 = 20.000% / 32.61%; all five thresholds 0.000% / 0.00% |
| `ceiling-export` (new) | 1448, 65536, 131072, 262144, 393216, 524288, 524288 | 1901992 | 2 at max 524288 = 28.571% / 55.13%; 65536: 85.714% / 99.92%, 131072: 71.429% / 96.48%, 262144: 57.143% / 89.59%, 524288: 28.571% / 55.13%, 1048576: 0.000% / 0.00% |

Four of the five thresholds are non-zero on `ceiling-export` (the spec's fixture scenario asks for
at least three).

The three rc5 bundles, from the same standalone reader over a fresh `xctrace` export of each
bundle's `os-signpost` table — this is the independent check on the script's ceiling line and the
source of the record's *derived* rows, which the ceiling line alone cannot give:

| | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Chunks / bytes | 15142 / 399024609 | 19709 / 363650368 | 26494 / 491356162 |
| Max / at max | 262144 / 65 | 262144 / 65 | 262144 / 65 |
| Chunks at or above 65536 / 131072 | 1143 / 465 | 172 / 98 | 265 / 133 |
| Extra chunks if the cap were 131072 (each chunk split into ⌈size ÷ cap⌉ pieces) | +465 (+3.1%) | +98 (+0.5%) | +133 (+0.5%) |
| Extra chunks if the cap were 65536 | +1819 (+12.0%) | +345 (+1.8%) | +482 (+1.8%) |
| Whole multiples of 1448 bytes | 13017 (86%) | 19390 (98%) | 25969 (98%) |

All of these reproduce design.md's Context table exactly.
