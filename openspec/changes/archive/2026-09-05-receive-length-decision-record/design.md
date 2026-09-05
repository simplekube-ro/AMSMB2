## Context

See proposal.md — Why. The pre-check numbers, computed on 2026-09-05 from
`../RandomPlayer/profiling/rc5-run{1,2,3}.trace` (6.0.0-rc5, cap 256 KB) by exporting the
`os-signpost` table and histogramming `InboundChunk` sizes of subsystem `ro.SimpleKube.AMSMB2`:

| | Run 1 (outlier) | Run 2 | Run 3 (median) |
|---|---|---|---|
| Chunks / bytes | 15 142 / 399 MB | 19 709 / 364 MB | 26 494 / 491 MB |
| Median / p95 / p99 / max (bytes) | 15 928 / 92 672 / 218 788 / 262 144 | 14 480 / 27 512 / 60 816 / 262 144 | 14 480 / 28 960 / 66 608 / 262 144 |
| Chunks at the cap (262 144) | 65 = 0.43 % (4.3 % of bytes) | 65 = 0.33 % (4.7 % of bytes) | 65 = 0.25 % (3.5 % of bytes) |
| Chunks ≥ 128 KB | 3.07 % (22.7 % of bytes) | 0.50 % (6.3 % of bytes) | 0.50 % (5.9 % of bytes) |
| Chunks ≥ 64 KB | 7.55 % (38.3 % of bytes) | 0.87 % (8.2 % of bytes) | 1.00 % (8.4 % of bytes) |
| Extra chunks if cap = 128 KB (each over-cap chunk split at the cap) | +465 (+3.1 %) | +98 (+0.5 %) | +133 (+0.5 %) |
| Extra chunks if cap = 64 KB | +1 819 (+12.0 %) | +345 (+1.8 %) | +482 (+1.8 %) |
| Chunks that are whole multiples of 1448 bytes | 86 % | 98 % | 98 % |

The 65 at-cap chunks per run are spread over the run (first at 0.1–0.4 s, last at 6.5–10.7 s)
and across 9–13 delivery threads: the fill's tail, not one phase. The identical count of 65 in
three runs of different length (15 142 / 19 709 / 26 494 chunks) is unexplained, and an exact
invariant across runs that differ in every other respect is the signature of a systematic artefact
rather than of a coincidence — so it is recorded as an open observation and carries a caveat in
the record. It does not move the decision either way: the bound holds whatever the explanation is.
If the 65 is real saturation, raising the cap can remove at most those 65 chunks; if some of the
65 are non-saturating reads that happened to return exactly the cap, the at-cap count *overstates*
what raising could remove, so the bound is only more conservative. The independent recomputation
by the committed script (task 3.1) is the falsification: the record states whatever the script
prints, and if that is not 65 the pre-check table is wrong and is corrected before the record is
written.

The pre-check's lowering figures (the two "extra chunks if cap = …" rows) are *derived*, not
measured: each over-cap chunk is split at the hypothetical cap. A real capture at a lower cap
would also re-clock the receive loop, so the split is a first-order estimate of the cost, not a
prediction — and it is the only figure the record needs, because the estimate is already the
argument against lowering.

This change decides *not* to modify the transport, so the before/after delta that
`docs/PROFILING.md` ("Using the baseline", step 3) requires of an inbound-path change does not
apply: there is nothing to capture a delta against. The record says so, so that it is not read as
a change that skipped the rule.

Why the bundles bound the sweep: with the receive minimum at 1, NWConnection completes a
receive as soon as the socket has data, so a chunk is smaller than the cap unless the kernel
queued more than the cap between two callbacks. Since #45 there is one chunk per read, so the
cap is exactly the ceiling of the `InboundChunk` distribution. Raising the cap can only merge
chunks that are at the cap; lowering it can only split chunks above the new cap.

Existing tooling: `scripts/profile-summary.sh` prints `InboundChunk` count, bytes and
min / median / p95 / max, pinned by three fixtures under `test-fixtures/profiling/` with
`expected.txt` each and covered by `SignpostContractTests` for the five names.

## Goals / Non-Goals

**Goals:**

- The record in `docs/PROFILING.md` is reproducible from any bundle with the committed script
  alone, and states the decision rule and the revisit condition.
- The summary script gains the one metric the sweep question needs and nothing else.

**Non-Goals:**

- Any device capture, harness, or transport change. `minimumIncompleteReceiveLength` stays out
  of scope as #46 states.
- Explaining the 65-chunk coincidence.

## Decisions

**D1 — One ceiling line after the `InboundChunk` size line, fixed thresholds.** Format
(one line, deterministic):

```
  InboundChunk     ceiling: 65 chunks at the max size 262144 (0.245% of chunks, 3.47% of bytes); at or above 65536: 1.000% / 8.44%, 131072: 0.502% / 5.94%, 262144: 0.245% / 3.47%, 524288: 0.000% / 0.00%, 1048576: 0.000% / 0.00%
```

Shares of chunks are printed to three decimals, shares of bytes to two — deliberately finer
than the one decimal the per-thread table uses (the script's only other percentage), because
at-cap chunk shares are fractions of a percent while their byte shares are whole percents. The
thresholds are the #46 sweep bounds; fixing them keeps the line comparable across captures. With
no `InboundChunk` events the line prints `ceiling: n/a`.

*What the line does and does not measure:* the ceiling is the receive length only where the
coalescing ratio is 1.00 — a TCP capture of 6.0.0-rc5 or later, where `channelRead` emits one
`TransportRead` and forwards exactly that buffer as one `InboundChunk`
(`AMSMB2/TCPTransportApple.swift:615`). On a pre-#45 bundle read with `--pairing global`, or on a
QUIC capture (the `no-transport-read-export` fixture's shape), the maximum is a coalesced maximum
and reads the cap only by accident. The script already prints the coalescing ratio two lines
below, so the qualification is available where the metric is; the requirement and the document
both state it. *Why not compute the ceiling from `TransportRead` instead* (which is the receive
cap directly): it would print `n/a` on exactly the captures that have no reads while the chunk
figures are the ones every other line is expressed in — one caveat is cheaper than a second
distribution. *Why not p99 in the size line:* that
would change the format of the five size/duration lines and every fixture; the ceiling line
carries what #46 needs. *Alternative:* a separate script (rejected: the point of the metric is
to appear in every summary next to the numbers it qualifies).

**D2 — TDD through the fixtures, plus one new fixture for the thresholds.** The three
`expected.txt` files gain the ceiling line, computed by hand from each fixture's chunk sizes,
before the script changes. The `no-transport-read-export` fixture still has chunks, so it
exercises the line too.

The three existing fixtures top out at 1 500-byte chunks, so on all of them every one of the five
threshold shares is `0.000% / 0.00%`: they pin the at-max half of the line and give the threshold
accumulation no coverage at all — a wrong comparison or a wrong denominator there would diff
clean. A fourth export fixture, `ceiling-export`, is therefore added: a minimal `time-profile.xml`
plus an `os-signpost.xml` whose `InboundChunk` sizes straddle the five thresholds (one below
64 KB, one at each of 64 KB, 128 KB and 256 KB, one between 256 KB and 512 KB, and two equal to
the maximum so the at-max count is not 1), with its own `expected.txt` and a fourth `diff` command
in `docs/PROFILING.md`. It is a synthetic fixture in the existing form — no new mechanism.
*Alternative rejected:* enlarging the existing fixtures' chunk sizes, which would churn every
other line of all three `expected.txt` files for no added coverage.

A fixture without chunks is not added; the `n/a` branch is checked by running the script on a copy
of a fixture with the `InboundChunk` rows removed, as an ad-hoc check whose exact command and
output line are recorded in tasks.

**D3 — The record's reading and rule.** The subsection states, in this order:

1. *Measured.* The cap is reached by 0.25–0.43 % of chunks (65 per run, 3.5–4.7 % of bytes); the
   median chunk is 14–16 KB and 86–98 % of chunks are whole multiples of 1 448 bytes. The
   distribution is set by TCP segment cadence and by `minimumIncompleteReceiveLength` staying at
   1 — a receive completes as soon as the socket has data — not by the cap.
2. *Raising the cap.* It can only merge chunks that are at the cap, so it removes at most 65
   chunks per run — under 0.43 % of op count, about 1.6 ms of the 25 µs-per-chunk chain
   (`docs/PROFILING.md`, After) over a 5.8–11.3 s fill. Stated as an upper bound, with the 65-chunk
   caveat from Context.
3. *Lowering the cap.* Derived by splitting each over-cap chunk at the hypothetical cap (labelled
   as derived, not measured): +0.5 % / +1.8 % chunks at 128 KB / 64 KB on the two clean runs,
   +3.1 % / +12.0 % on the run-1 outlier. Reported per run — never averaged, since run 1 is the
   documented outlier — and read as: lowering has a cost and no identified benefit
   (`maximumReceiveLength` caps what a completion returns; it does not pre-allocate, so a smaller
   value buys no memory).
4. *Decision.* Keep `1 << 18`, and say explicitly that this is a decision not to change the
   transport (see Context).
5. *Revisit rule.* Re-open #46 if a capture taken by the standard procedure shows an at-cap share
   above **5 % of chunks**, or if `minimumIncompleteReceiveLength` is ever raised above 1, which
   changes the premise the whole reading rests on.

The 5 % threshold is a **shape-change tripwire, an order of magnitude above every rc5 run
(0.25–0.43 %) — not a break-even point**, and the record states the arithmetic so the next reader
can move it: at a 5 % at-cap share, run 3's 26 494 chunks would put ~1 325 chunks at the cap, and
merging every one of them saves at most 1 325 × 25 µs ≈ 33 ms over a ~10 s fill — still under a
tenth of what the #45 conversion removed (15 µs × 26 494 ≈ 0.4 s). A share that made raising the
cap worth the #45-sized effort would be tens of percent. 5 % is chosen because it is the point at
which the capture no longer looks like the one this decision was taken on, which is the honest
trigger for re-measuring; it is deliberately conservative. Sourcing it from the run-to-run spread
of a different metric was rejected (see the superseded change's review).

**D4 — The transport comment.** One sentence appended to the existing comment block on the
option, naming the subsection, so the "should be measured" note from #43 is closed at the
line itself.

## Risks / Trade-offs

- [The rc5 bundles are one device, one server, three runs] → stated in the record; the revisit
  rule gives the next capture a threshold to check against, and the ceiling line makes that a
  one-line read.
- [Rounding in the ceiling line differs from the hand histogram] → the record is regenerated
  from the updated script on the three bundles, not copied from the pre-check.
- [`xctrace export` segfaults intermittently] → the script already retries three times.
- [The record is read as a measured comparison of cap values] → every derived figure is labelled
  as derived and its derivation stated (D3 items 2 and 3); the record says no capture at another
  cap was taken and why one cannot change the bound.
- [The ceiling line is read off a capture whose coalescing ratio is not 1.00] → the caveat is in
  the requirement, in the script's header comment and in the document's Metrics row (D1).

## Migration Plan

None. Docs and tooling only.
