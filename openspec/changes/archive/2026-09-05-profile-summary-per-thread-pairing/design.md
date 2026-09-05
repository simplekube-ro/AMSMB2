## Context

See proposal.md — Why. Current state that shapes the approach:

- `scripts/profile-summary.sh` is bash around one inline python3 program. `load_table` returns
  every signpost row as a dict of mnemonic → resolved element, so the `thread` cell (a
  `<thread>` element holding a `<tid>` child, interned by `id`/`ref` like every other value) is
  already available to the pairing pass; today only the time-profile side reads it, for the
  thread label. Signpost events are tuples `(ts, order, name, kind, ident, value)`.
- The pairing pass is one global `deque`: zero-byte reads skipped, reads pushed, each chunk pops
  reads until the bytes sum to its size; overshoot and underflow are collected as pairing
  errors and every error is printed on its own line after the latency percentiles.
- Emission contract (main spec, Inbound path signposts; `InboundSignposts.chunk` doc comment):
  since #45 the TCP transport emits `TransportRead` and then hands the chunk to the bridge,
  which emits `InboundChunk`, inside one network callback on the network stack's delivery
  thread. Callbacks on one thread are serialized, so on any thread at most one read is ever
  waiting for its chunk. The only unpaired read is one that races bridge teardown (the bridge
  drops the delivery, no chunk follows). A recording attached to a running app can start
  between a read and its chunk (attach carry-over: a chunk with no read before it), and a
  recording can stop between the two (a trailing read).
- Verified on the six local bundles (`../RandomPlayer/profiling/{rc5,baseline}-run{1,2,3}.trace`,
  exported once into a scratch directory and walked by a throwaway probe) before writing this
  design. The one-pending-read-per-thread rule below gives exactly the numbers the issue quotes
  for rc5 — 15141 / 19708 / 26494 pairs, 1 / 1 / 0 carry-over chunks, 0 unpaired reads, 0 byte
  mismatches, medians 0.002 ms and p95 0.012 / 0.008 / 0.007 ms, maxima 5.551 / 0.578 / 2.078 ms
  — while the current global FIFO reports 14987 / 19708 / 26494 pairs with 155 / 1 / 0 errors.
  On the rc4 baseline bundles the same rule is meaningless (run 1: 6494 "pairs", 9442
  carry-overs, 9443 unpaired reads, 5183 mismatches, maximum "latency" 20 s), and the issue's
  proposed detector does not fire: every chunk thread of baseline runs 1 and 3, and 12 of 13 in
  run 2, also emitted reads. The global FIFO on the baseline reproduces the recorded Baseline
  numbers (run 2: 6207 pairs, 0 errors, 0.016 / 0.031 / 0.372 ms).
- The committed fixture `test-fixtures/profiling/sample-export` puts reads on `0x101`
  (`NIO-SGLTN-1-#1`) and chunks on `0x102` (`RandomPlayer`), with one three-reads-to-one-chunk
  group — a pre-#45 shape by construction. Its `expected.txt` is the only automated check of
  the script (a documented `diff`; nothing in `swift test` or CI runs it).

## Goals / Non-Goals

**Goals:**

- Exact pairing on post-#45 captures regardless of how many connections interleave, with the
  two legitimate non-pairs (carry-over, teardown-race read) named and counted, not reported as
  errors.
- The pairing mode is never implicit: it is chosen by the operator and printed in the output.
- Both modes and the no-read branch pinned by hand-written fixtures whose expected output is
  derived by hand from their timelines, and the per-thread fixture demonstrates the defect (its comment states what the global
  FIFO reports for the same rows).
- No change to any output line outside the pairing block, so recorded summaries stay
  comparable line for line except for that block; the two script-output blocks pasted in
  `docs/PROFILING.md` are regenerated from the archived bundles with the new script (D6).

**Non-Goals:**

- Auto-detecting the capture generation (see D2).
- Re-summarising or re-recording the Baseline or After sections. The After table already
  carries the hand-computed per-thread numbers; this change makes the script print them, and
  the doc notes that, without re-running the procedure.
- Running the fixture `diff` from `swift test` or CI. Worth doing, but a separate change to the
  test infrastructure, not this script fix.
- Pairing across threads for any reason (for example a heuristic that lets a chunk pick up a
  read from another thread). Cross-thread pairing is exactly what mispairs.

## Decisions

### D1. Per-thread pairing keeps one pending read per thread

Events of the two names are walked in `(ts, order)` order, as today. Per thread (keyed by the
`tid` text of the row's `thread` cell, resolved through the same back-reference resolver as
every other cell):

- `TransportRead` with zero bytes: skipped and counted, as today (cannot occur post-#45; kept
  so the two modes share the read filter).
- `TransportRead`: if a read is already pending on that thread, that earlier read is counted
  as an **unpaired read** (its chunk never came — the teardown race); the new read becomes the
  pending one.
- `InboundChunk` with no pending read on its thread: counted as a **chunk without a read**. On
  a TCP-only capture that is the attach carry-over (the read preceded the recording; at most one
  per attach) or a read signpost xctrace dropped; on a capture that includes a QUIC connection it
  is every QUIC chunk, because the QUIC transport does not emit `TransportRead` (main spec,
  Inbound path signposts). The label therefore names the observation, not one cause, and the
  Metrics row lists the three causes and their expected magnitudes.
- `InboundChunk` with a pending read of equal bytes: paired; latency = chunk ts − read ts.
- `InboundChunk` with a pending read of different bytes: a **pairing error**, printed as
  `mismatch: InboundChunk B bytes at T ns on <thread label>, pending TransportRead R bytes` where
  the thread label is the existing `thread_label()` form used by the per-thread CPU table (e.g.
  `NIO-SGLTN-1-#1 (0x101)`); the error consumes both the pending read and the chunk — neither is
  counted as a read without a chunk or a chunk without a read.
- At the end, every still-pending read is a **read without a chunk**.

Every event of the two names lands in exactly one bucket, which gives two invariants a reader
can check against any summary, including the hand-written `expected.txt`:
`pairs + chunks without a read + pairing errors == InboundChunk count` and
`pairs + reads without a chunk + pairing errors + zero-byte skipped == TransportRead count`.

Why not a per-thread byte-sum FIFO (the current algorithm partitioned by thread): post-#45 no
chunk is ever the sum of several reads, so a byte-sum search can only invent pairs — a
carry-over chunk would swallow later reads until their sizes happen to add up, hiding both the
carry-over and the mispairing. The one-pending-read rule encodes the emission contract and makes
every deviation from it visible under its own name. Why count the superseded read as a read
without a chunk rather than an error: the Metrics table already documents that read as expected
("at most a couple per connection, at the end"); calling it an error would make every clean
capture report errors.

### D2. `--pairing per-thread|global`, default `per-thread`, mode printed; no auto-detection

The issue proposed falling back to the global FIFO "when a thread's `InboundChunk` events have
no `TransportRead` events on the same thread". On the actual baseline bundles that predicate is
false for 30 of 31 chunk threads (Context): the pump `Task`s ran on Dispatch worker threads that
also served as NIOTS delivery threads, so a pre-#45 capture has reads on nearly every chunk
thread, the detector chooses per-thread mode, and the output is garbage that still says "pairs".
A detector keyed on mismatch counts instead would be a threshold on the very data being measured
and would flip a clean post-#45 run to global mode on a single lost signpost (xctrace reported
`log/signpost messages lost due to high rates` on Baseline run 1).

So the mode is an explicit input. The default is per-thread because every capture of the
shipped code (6.0.0-rc5 onward) is post-#45; `--pairing global` exists for the rc4 Baseline
bundles and the pre-#45-shaped fixture. Both modes print a `pairing:` line so a summary can be
read on its own. The option is parsed in bash before the positional argument (usage:
`profile-summary.sh [--pairing per-thread|global] <bundle.trace | export-dir>`) and passed to
the python program as a third argument; an unknown value is a usage error (exit 1, one line).

Alternative rejected: making global the default to keep the fixture command unchanged. That
would leave the shipped code's captures on the wrong default and repeat the "trustworthy only on
a zero-error run" situation the issue is about.

### D3. Output shape

Only the pairing block changes; every line before `coalescing ratio` and after `pump-hop
latency` is byte-identical to today. The block, in per-thread mode:

```
  coalescing ratio: 1.00 (26494 TransportRead / 26494 InboundChunk)
  pairing: per-thread (10 delivery threads)
  zero-byte TransportRead skipped: 0
  pump-hop latency ms: min 0.001 / median 0.002 / p95 0.007 / max 2.078 (26494 pairs, 0 chunks without a read, 0 reads without a chunk, 0 pairing errors)
    pairing error: mismatch: ...        (one line per error, as today)
```

In global mode:

```
  coalescing ratio: 1.60 (8 TransportRead / 5 InboundChunk)
  pairing: global FIFO (byte-sum across threads; for captures before the inbound push-conversion, #45)
  reads per chunk: 1 read x4, 3 reads x1
  zero-byte TransportRead skipped: 1
  pump-hop latency ms: min 0.100 / median 0.200 / p95 0.900 / max 0.900 (5 pairs, 0 pairing errors)
```

- `pairing:` sits right after the coalescing ratio because the three lines below it are the
  ones whose meaning depends on the mode.
- "delivery threads" = the number of distinct `tid`s that emitted `TransportRead` or
  `InboundChunk` in the subsystem. The After table calls this "Connections (threads emitting
  `TransportRead`)"; the line uses the neutral word because NIOTS may serve two connections from
  one loop thread (the rule still holds — callbacks on one thread are serialized — but the count
  then undercounts connections). The doc row gets the same wording.
- `reads per chunk` is global-mode only (proposal). The global mode's latency suffix is
  unchanged so the existing fixture and the recorded summaries stay comparable.
- When there are no `TransportRead` events the two `n/a` lines are printed as today and the
  `pairing:` line is still printed (the mode is an input, not a result), so a QUIC capture says
  which mode it would have used. That shape is pinned by the third fixture (D4).

### D4. Fixtures: keep the existing one for global mode, add one for per-thread mode

The existing fixture is a correct pre-#45 sample, not a bug (the issue allowed for either): its
coalesced group cannot exist post-#45 and is the case the global FIFO was written for. Rewriting
it to post-#45 shape would lose the only pinned exercise of the byte-sum path. It stays, run with
`--pairing global`; its `expected.txt` gains the `pairing:` line and its header comment gains one
sentence saying it is pre-#45 shaped and why.

`test-fixtures/profiling/per-thread-export/` is new: `time-profile.xml` is a copy of the existing
fixture's (the per-thread table is not what it pins; three threads, ten samples), `os-signpost.xml`
is hand-written in the same style (schema on the first `<node>`, rows split over two nodes,
interned values, `uint64` metadata) with two delivery threads `0x101` and `0x103` whose reads
and chunks are emitted on their own thread, and the pass/drain rows on `0x102`. Its timeline
contains, in this order:

1. a carry-over chunk on `0x101` (no read before it);
2. an interleaved group that the global FIFO gets wrong: `0x101` read 1500, `0x103` read 500,
   `0x103` chunk 500, `0x101` chunk 1500 — global pops the 1500 read for the 500 chunk
   (overshoot) and then finds nothing for the 1500 chunk (underflow), the exact
   overshoot/underflow pair the issue describes; per-thread pairs both with their own latency;
3. a byte mismatch on `0x101` (read 800, chunk 900) — one pairing error;
4. a read of 600 on `0x103` followed by a read of 700 on `0x103` before any chunk (the 600 read
   becomes a read without a chunk), then the chunk of 700 for the second;
5. a trailing read of 400 on `0x101` with no chunk (a read without a chunk at the end);
6. enough `RecvDrain`, `ServiceDispatch` and `ServicePass` rows on `0x102` to give every line of
   the output a defined value, kept minimal.

The header comment lists the timeline, the expected numbers for per-thread mode, and what
global mode reports for the same rows (pairs, errors), so the fixture is also the regression
demonstration. `expected.txt` is derived by hand from the timeline before the script is
changed (TDD Red), like the first fixture was, and its counts satisfy the D1 invariants.

A third fixture, `test-fixtures/profiling/no-transport-read-export/`, is the per-thread fixture
with every `TransportRead` row removed (the shape of a QUIC capture or of a bundle from a build
before the signposts), with its own `expected.txt`: the `pairing:` line, `n/a` for the
coalescing ratio and the pump-hop latency, no error lines. The fixture `diff`s are the script's
only automated coverage, so the no-read branch is pinned by a committed fixture rather than by a
throwaway copy made during verification.

### D5. Thread column handling and failure modes

- The `thread` mnemonic joins the `required` columns of the signpost table; a row of the
  subsystem with a `<sentinel/>` thread cell, or a `thread` element without a `tid` child, is a
  `Fail` (exit 1, one line) — the same policy the time-profile side applies to a sample without a
  thread. Silently dropping such a row would corrupt the pairing.
- The key is the `tid` element's text (decimal in the export; the hex form lives in `fmt`).
  Each event tuple carries the tid and the `thread_label()` of the row's thread element (the
  same label the per-thread CPU table prints), so the mismatch line never shows a decimal tid
  dressed as hex; no other consumer of the tuple changes.
- `--pairing global` on a post-#45 capture behaves exactly as the script does today (that is how
  the recorded After summaries were produced), so an operator who forgets the flag on an old
  bundle or adds it on a new one gets today's numbers, never a crash.

### D6. Documentation changes

`docs/PROFILING.md`:

- Export and summarise: usage with the flag; the fixture paragraph names the three fixtures and
  shows the three `diff` commands (`--pairing global` for `sample-export`, default for
  `per-thread-export` and `no-transport-read-export`).
- Metrics table: the Coalescing ratio row loses the "plus the reads-per-chunk distribution"
  clause for the default mode (it becomes "in global mode also …"); the Pump-hop latency row
  describes the per-thread rule, the three causes of a chunk without a read (attach carry-over,
  dropped signpost, QUIC chunk) with their expected magnitudes, the read without a chunk, and says the global
  byte-sum FIFO is selected with `--pairing global` for captures before #45.
- The two pasted script-output blocks are literal output of the pre-#69 script and would no
  longer be reproducible from the doc's own command: the Baseline block (`docs/PROFILING.md`,
  Baseline, run 2) lacks the `pairing:` line, and the After block (After, run 3) lacks it, has a
  `reads per chunk` line that per-thread mode does not print, and its latency suffix lacks the
  carry-over and unpaired counts. Both are regenerated from the archived bundles with the new
  script (task 3 saves the output): the Baseline block with `--pairing global`, the After block
  in default mode. Every number outside the pairing block is unchanged by construction, and the
  probe in Context showed the After pairs and percentiles are identical too (run 3: 26494 pairs,
  0 errors in both modes), so the record changes shape, not values; the subsection says the
  block was regenerated with the #69 script.
- After section table: the rows "Connections (threads emitting `TransportRead`)" and "Pump-hop
  latency …, per-thread pairing" get a one-line note that the script now prints both (the
  values were recomputed by hand for PR #68 and are unchanged — the probe reproduced them); the
  "Global-FIFO pairing errors reported by the script" row is annotated as pre-#69 output. The
  procedure note that says "Keying the script's pairing by thread is a follow-up" is rewritten
  to say it is done (#69) and how the carry-over now reads.
- Using the baseline: step 2 says the rc4 Baseline bundles need `--pairing global`.

`scripts/profile-summary.sh` header comment: Usage gains the flag; the Conventions bullet on
pairing describes both modes and the new counts.

## Risks / Trade-offs

- [Two connections on one NIOTS loop thread] → the pairing stays exact (callbacks on one thread
  are serialized, so still at most one pending read); only the "delivery threads" count
  undercounts connections. The line and the doc row say "delivery threads", not connections.
- [A lost `TransportRead` signpost (xctrace drops under load)] → its chunk is counted as a
  chunk without a read, not an error; a lost `InboundChunk` makes its read a read without a
  chunk. Both are
  visible as counts above the expected "≤ 1 carry-over, a few unpaired reads at the end"; the
  doc's Metrics row states the expected magnitudes so an operator can tell a lossy recording from
  a clean one.
- [Operator runs a pre-#45 bundle without `--pairing global`] → thousands of chunks without a
  read, reads without a chunk and mismatches are printed next to the pair count, which cannot be mistaken for
  a clean run; the doc names the bundles that need the flag. Accepted in exchange for never
  guessing the mode (D2).
- [The existing fixture's `expected.txt` changes by one line] → the change is additive and
  every other line is unchanged; the `diff` command in the doc gains the flag in the same commit.
- [xctrace export variants without a `thread` column on signpost rows] → the script fails with a
  one-line message naming the missing column (existing `required` mechanism) rather than pairing
  everything on one phantom thread. All six local bundles (Xcode 26.6) carry the column.
