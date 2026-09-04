# Profiling the inbound path

## Purpose

This document is the repeatable procedure for capturing a Release-build, on-device baseline of
AMSMB2's SMB-over-NIO inbound path, so that the deferred transport work (inbound push-conversion,
receive-length tuning) is judged by a before/after delta rather than by an observer-noise trace.
The library emits `os_signpost` data at the five points that define the streaming-read hot path;
this document names the instrument filter that selects them and the workload that produces them.

The numbers here gate [issue #45](https://github.com/simplekube-ro/AMSMB2/issues/45) (inbound
push-conversion) and [issue #46](https://github.com/simplekube-ro/AMSMB2/issues/46)
(`maximumReceiveLength` tuning); the baseline itself is
[issue #44](https://github.com/simplekube-ro/AMSMB2/issues/44). Neither follow-up merges without
a before/after delta computed by this procedure and `scripts/profile-summary.sh`.

Why the previous captures do not count: both Debug bundles taken during PR #43 were launched
from the Xcode debugger (their process list contains `libBacktraceRecording.dylib` and
`libLogRedirect.dylib`), one of them also recorded the GCD and Hangs instruments, and roughly
three quarters of the headline CPU in that trace was Instruments overhead. Nothing in that data
separates the cooperative-pool pump hop from the rest.

## Prerequisites

- Xcode 26.6 or later on the Mac. This procedure was written against
  `xctrace version 16.0 (17F113)`; record the `xcrun xctrace version` output with every capture.
- A physical Apple TV provisioned for development and paired with the Mac (primary target:
  "Birou", tvOS 26.6). iPhone/iPad follow the same steps with the iOS destination; no baseline is
  recorded for them.
- The RandomPlayer project checked out next to this repository (`../RandomPlayer`), pinned to the
  AMSMB2 version under test (`requirement = exactVersion` in `RandomPlayer.xcodeproj`; the
  baseline needs `6.0.0-rc4` or later, the first tag that emits the signposts). Record the
  RandomPlayer commit alongside the AMSMB2 version.
- A Samba share reachable from the Apple TV over TCP holding the representative video. The video
  is named by the operator at capture time and recorded in the Baseline section; every later
  capture that is compared against the baseline uses the same file.
- `python3` (ships with the Xcode command-line tools) for the summary script.

## Build

Build and launch through **Product ▸ Profile** with the Apple TV as the run destination. The
shared RandomPlayer scheme builds **Release** for the Profile action; that is the only supported
way to produce a trace for this procedure. Never launch from Product ▸ Run and attach Instruments
afterwards: a debugger launch injects `libBacktraceRecording.dylib` and `libLogRedirect.dylib`
into the process, and their presence in a bundle's process list disqualifies the capture. Check
every bundle before summarising it:

```
xcrun xctrace export --input <bundle.trace> \
  --xpath '/trace-toc/run[1]/processes' --output processes.xml
grep -c 'libBacktraceRecording.dylib\|libLogRedirect.dylib' processes.xml   # must print 0
```

Always pass `--output` to `--xpath` exports; a table export written to a pipe that closes early
crashes instead of failing cleanly (the small `--toc` listing below is safe to pipe).

## Instruments

Add the `os_signpost` instrument to a Time Profiler recording and filter it to:

```
subsystem: ro.SimpleKube.AMSMB2
category: Inbound
```

These two identifiers are pinned to the constants the library emits under by
`AMSMB2Tests/SignpostContractTests.swift` — renaming either side without the other fails the
unit suite.

In the Instruments GUI (after Product ▸ Profile opens the template chooser):

1. Choose the **Time Profiler** template.
2. Delete the **Hangs** track from the document (it ships with the template and adds overhead).
   Do **not** add the GCD instrument.
3. Add the **os_signpost** instrument from the library and, in its track settings, filter the
   subsystem to `ro.SimpleKube.AMSMB2`.
4. Press Record, run the workload below, press Stop, and save the bundle.

Equivalent command line (device-only; the app must already be installed on the Apple TV by the
Profile build, and `<udid>` comes from `xcrun xctrace list devices`):

```
xcrun xctrace record --device <udid> --template 'Time Profiler' \
  --instrument os_signpost --time-limit 3m \
  --output baseline-run1.trace --launch -- ro.SimpleKube.RandomPlayerApp
```

Verify the instrument set of the saved bundle from its table of contents: `Hangs` must not
appear as an instrument, and both the `time-profile` and `os-signpost` schemas must be present.

```
xcrun xctrace export --input <bundle.trace> --toc \
  | grep -E -o '<instrument name="[^"]*">|schema="(time-profile|os-signpost)"' | sort -u
```

## Workload

The Apple TV is driven with the Siri Remote, so the steps are performed by the operator. Keep
them identical across runs:

1. Open RandomPlayer, browse to the Samba share, and start the representative video.
2. Let it play for **120 s** of steady-state playback without touching the remote.
3. Perform **five seeks** at fixed offsets: 25%, 50%, 75%, 10%, 90% of the file, waiting **10 s**
   after each seek before the next.
4. Stop the recording.

Note any stall (playback freeze, spinner, audio drop) with its approximate time; stalls are part
of the recorded baseline.

A single run is not a baseline. Capture **three** runs and report the median run (by
`ServicePass` median duration; note the other two in the run log).

## Export and summarise

```
scripts/profile-summary.sh <bundle.trace>
```

The script exports the `time-profile` and `os-signpost` tables with `xcrun xctrace export
--xpath`, resolves the export's `ref`/`id` back-references, and prints the metrics below as plain
text. It also accepts a directory that already holds `time-profile.xml` and `os-signpost.xml`;
`test-fixtures/profiling/sample-export/` is a hand-written export whose exact output is pinned in
`expected.txt`, which is how the parsing and arithmetic are verified without a device:

```
diff <(scripts/profile-summary.sh test-fixtures/profiling/sample-export) \
     test-fixtures/profiling/sample-export/expected.txt
```

The fixture pins the parser's arithmetic, not the export format. After changing the parser, also
record a throwaway macOS program that emits the five names through `os_signpost` (same
subsystem, category, `bytes=%ld` / `terminal=%ld` formats) with
`xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --launch -- <binary>`
and run the script on that bundle: a real export splits a table across several `<node>`
elements and interns repeated values inside metadata cells, shapes a hand-written fixture is
prone to miss.

`xctrace` 16.0 occasionally crashes during an export (exit 139, segmentation fault); the script
then reports the failed table and exits 1 without parsing a truncated file. Re-run it.

Percentiles are nearest-rank (median = p50). A bundle without the subsystem's signposts prints
the per-thread table followed by `no ro.SimpleKube.AMSMB2 signposts` and exits 0; an unreadable
path or a bundle with no time-profile table exits 1 with a one-line message.

## Metrics

The inbound path is a pull loop with two executor hops per burst. The signposts measure the two
hops separately:

| Metric | Source | Definition |
|---|---|---|
| Per-thread CPU | `time-profile` | Samples per thread and share of total. The unnamed `RandomPlayer (0x…)` threads are the Swift cooperative pool; `NIO-SGLTN-*` is the NIOTS event loop; the cooperative-pool share is the signature #45 should shrink. |
| `TransportRead` | event, bytes | One per chunk the TCP transport receives on the network stack's queue. **TCP transport only** — a QUIC capture has none, and the script prints `n/a` for the two derived metrics instead of pairing errors. |
| `InboundChunk` | event, bytes | One per non-empty chunk the bridge appends to its FIFO. Total `InboundChunk` bytes equal total `TransportRead` bytes: coalescing changes counts, never bytes. |
| Coalescing ratio | derived | `TransportRead` count ÷ `InboundChunk` count, plus the reads-per-chunk distribution. When the pump `Task` is behind, several reads accumulate and are handed over as one chunk; a ratio above 1 is direct evidence of pump backlog. |
| Pump-hop latency | derived | For each `InboundChunk` the script pops `TransportRead`s in FIFO order until their bytes sum to the chunk size and reports chunk time − first popped read time: the queueing delay of the oldest coalesced byte. This is the network-queue → cooperative-pool hop that #45 removes. |
| `ServiceDispatch` | interval | From the inbound-ready signal arming a pass (debounce accepts) to the armed signal being cleared: the pass beginning on `eventLoopQueue`, or teardown clearing it first. This is the debounce + queue hop that stays after #45. |
| `ServicePass` | interval, `terminal=0/1` | One signal-driven service pass (`smb2_service`, outbound flush, timer reschedule). `terminal=1` means the seam was gone when the pass ended: the pass tore it down (service failure or flush failure) or teardown ran while the pass was already dispatched. Terminal passes are listed separately and excluded from the duration percentiles because they include teardown and context destruction. |
| `RecvDrain` | event, bytes | One per libsmb2 drain of the FIFO: bytes copied, `0` for EOF, `-1` for would-block. Total `RecvDrain` bytes never exceed total `InboundChunk` bytes; the difference is what was still buffered when recording stopped (`buffered at end`). |
| Throughput | derived | `RecvDrain` bytes ÷ wall-clock span between the first and last subsystem signpost, in MB/s (10⁶ bytes). |
| Stalls | operator | Playback freezes or spinners observed during the workload, with approximate times. |

How to read a `ServiceDispatch` interval that is closed with no following `ServicePass`: a chunk
armed a fresh signal while a pass was running, that pass then failed and tore the seam down, and
teardown cleared the armed signal. It is interval hygiene (nothing dangles), not a lost wakeup.
Likewise a dispatch interval whose pass was dequeued after the context was destroyed ends without
a pass interval.

Overhead bound: each emit costs roughly 1–2 µs while recording and one enablement check when not.
Multiply the signpost counts in the script output by that to bound the instrumentation's share of
the pass durations before reading anything into small deltas.

## Baseline

Not yet captured. Filled in by the operator gate of the `add-inbound-profiling-baseline` change
(tasks 5.x) from the median of three runs on the Apple TV.

| Field | Value |
|---|---|
| Date | |
| Device / OS | Apple TV "Birou", tvOS |
| AMSMB2 version | |
| RandomPlayer commit | |
| `xcrun xctrace version` | |
| Video | |
| Runs | 3 (median reported) |

Script output of the median run:

```
(pending)
```

Stalls observed: (pending)

## Using the baseline

For #45, #46, or any other change to the inbound path:

1. Same device, same video, same workload and duration, three runs, report the median.
2. Run `scripts/profile-summary.sh` on each bundle; never read numbers off the Instruments GUI.
3. Compare against the Baseline section above; the delta on pump-hop latency, coalescing ratio,
   per-thread cooperative-pool share and throughput is the evidence the PR must carry.
4. Record the new numbers under a dated subsection here when the change merges, so the next
   comparison has a baseline that matches the shipped code.

Faithfulness of an rc4 baseline to what PR #43 shipped (rc1): the inbound hot path is unchanged
between `6.0.0-rc1` and `6.0.0-rc3`, and rc4 adds only the signposts. Reproduce with:

```
git diff --stat 6.0.0-rc1..6.0.0-rc3 -- AMSMB2/TransportBridge.swift \
  AMSMB2/TCPTransportApple.swift AMSMB2/SMBTransport.swift      # empty
git diff 6.0.0-rc1..6.0.0-rc3 -- AMSMB2/Context.swift          # teardown/error paths only
```
