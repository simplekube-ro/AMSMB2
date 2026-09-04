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

Equivalent command line (device-only). Name the two instruments explicitly instead of
`--template 'Time Profiler'`: the template bundles the Hangs instrument and `xctrace` has no way
to remove it. Attach to the running app rather than `--launch`: over a network-connected Apple TV
the launch form hung indefinitely (0% CPU, ignored Ctrl-C, empty bundle) with `xctrace` 16.0,
while attaching completed and saved every time. Install the Release build with the Profile
action (or `xcrun devicectl device install app`), start it from the home screen or with
`xcrun devicectl device process launch --device <coredevice-id> ro.SimpleKube.RandomPlayerApp`
(not a debugger launch), take its pid from `xcrun devicectl device info processes`, then:

```
xcrun xctrace record --device <udid> --instrument 'Time Profiler' \
  --instrument os_signpost --time-limit 4m \
  --output baseline-run1.trace --attach <pid>
```

`<udid>` comes from `xcrun xctrace list devices`, which must list the Apple TV under
`== Devices ==` (not `Devices Offline`); if it is offline, wake the TV and open Xcode's Devices
and Simulators window until it shows connected. Attaching by name (`--attach RandomPlayer`)
resolves intermittently; the pid is reliable. Before the first real run, record a 15 s
attach and run the summary script on it: it must show the `ServiceDispatch` / `ServicePass`
rows from the idle app and no debugger library.

Verify the instrument set of the saved bundle from its table of contents: `Hangs` must not
appear as an instrument, and both the `time-profile` and `os-signpost` schemas must be present.

```
xcrun xctrace export --input <bundle.trace> --toc \
  | grep -E -o '<instrument name="[^"]*">|schema="(time-profile|os-signpost)"' | sort -u
```

## Workload

RandomPlayer caches aggressively: opening a video pulls the whole file from the share at full
speed into its local cache and plays from the local copy, so the SMB inbound path is exercised
by the cache fill, not by playback. Playback and seeks of a cached file never touch SMB, and a
file that has been opened once is served from the cache from then on. The workload is therefore
one cache fill, and the Apple TV is driven with the Siri Remote, so the operator performs it:

1. Start RandomPlayer and stop on the browse screen of the Samba share. Attach the recording
   (see above) while the app is idle, so the whole fill is captured.
2. Open a video that has **not been played before on this device** (not in Cache Management),
   of at least 1 GB, and record its name and size.
3. Leave it playing, hands off, until the fill is complete (at ~11 MB/s a 1 GB file takes about
   100 s; the recording's 4 min limit covers up to ~2.5 GB). No seeks are needed.
4. Note any stall (playback freeze, spinner, audio drop) with its approximate time.

Each run needs a different uncached file of comparable size, or the same file removed from
Cache Management between runs. A single run is not a baseline: capture **three** runs and
report the median run (by `ServicePass` median duration; note the other two in the run log).
Sustained throughput is bounded by the link between the Apple TV and the server, not by the
library, so compare the per-event metrics (coalescing ratio, pump-hop and dispatch latencies,
pass durations, per-thread shares) across runs rather than the MB/s figure.

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
| Throughput | derived | `RecvDrain` bytes ÷ wall-clock span between the first and last subsystem signpost, in MB/s (10⁶ bytes). The `active throughput` line excludes idle gaps longer than 1 s (the keepalive tail after a cache fill, and pauses inside it), which is the figure to compare. |
| Stalls | operator | Playback freezes or spinners observed during the workload, with approximate times. |

A recording attached to a running app starts mid-activity: its first rows can be a `RecvDrain`
inside a pass whose begin was never recorded (one `unpaired` `ServicePass` end), and those
bytes make `buffered at end` negative by that amount. That is attach-time carry-over, not a
counting error; it is bounded by one chunk.

How to read a `ServiceDispatch` interval that is closed with no following `ServicePass`: a chunk
armed a fresh signal while a pass was running, that pass then failed and tore the seam down, and
teardown cleared the armed signal. It is interval hygiene (nothing dangles), not a lost wakeup.
Likewise a dispatch interval whose pass was dequeued after the context was destroyed ends without
a pass interval.

Overhead bound: each emit costs roughly 1–2 µs while recording and one enablement check when not.
Multiply the signpost counts in the script output by that to bound the instrumentation's share of
the pass durations before reading anything into small deltas.

## Baseline

Captured 2026-09-04 on the Apple TV, three runs, median run reported (median by `ServicePass`
median duration: run 3 0.010 ms, **run 2 0.011 ms**, run 1 0.012 ms).

| Field | Value |
|---|---|
| Date | 2026-09-04 |
| Device / OS | Apple TV 4K (3rd generation) "Birou", tvOS 26.6, network-connected |
| AMSMB2 version | 6.0.0-rc4 (b919898) |
| RandomPlayer commit | 15654e10, pinned to AMSMB2 6.0.0-rc4 |
| `xcrun xctrace version` | xctrace version 16.0 (17F113), Xcode 26.6 |
| Video | `8513d1_1080_8000.mp4` (106 MB, complete fill) |
| Instruments | Time Profiler + os_signpost, attached to the running app, no debugger library in the process list |
| Runs | 3 (median reported) |

Script output of the median run (run 2):

```
Time profile: 98194 samples
  samples   share  thread
    16711   17.0%  Main Thread (0x155411)
    11087   11.3%  RandomPlayer (0x16c92f)
     7247    7.4%  RandomPlayer (0x16e4fa)
     6915    7.0%  RandomPlayer (0x16df39)
     6011    6.1%  RandomPlayer (0x167e87)
     5823    5.9%  RandomPlayer (0x16e919)
     5797    5.9%  RandomPlayer (0x16cd33)
     5110    5.2%  RandomPlayer (0x16c8cf)
     4746    4.8%  RandomPlayer (0x16a4b3)
     3978    4.1%  RandomPlayer (0x16e4f9)
     3762    3.8%  RandomPlayer (0x16df1e)
     3421    3.5%  RandomPlayer (0x16e444)
     2995    3.1%  RandomPlayer (0x16d68a)
     2361    2.4%  RandomPlayer (0x16ddc2)
     2304    2.3%  RandomPlayer (0x16bbcb)
     2113    2.2%  RandomPlayer (0x16e57f)
     1963    2.0%  RandomPlayer (0x16df1f)
      879    0.9%  RandomPlayer (0x16ea3e)
      867    0.9%  RandomPlayer (0x16dde6)
      784    0.8%  RandomPlayer (0x16ae43)
      654    0.7%  RandomPlayer (0x16553c)
      541    0.6%  RandomPlayer (0x16dde9)
      334    0.3%  RandomPlayer (0x16d92b)
      317    0.3%  RandomPlayer (0x16eb5a)
      280    0.3%  RandomPlayer (0x16eb5b)
      187    0.2%  RandomPlayer (0x16eacd)
      174    0.2%  RandomPlayer (0x16eb59)
      119    0.1%  RandomPlayer (0x16eacc)
      112    0.1%  RandomPlayer (0x16df2f)
       95    0.1%  RandomPlayer (0x16ed09)
       42    0.0%  com.apple.uikit.eventfetch-thread (0x155450)
       36    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x16ea0d)
       35    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16def6)
       30    0.0%  RandomPlayer (0x16e441)
       28    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16e8ad)
       25    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16e9ac)
       23    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16dbbe)
       22    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16ea30)
       21    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16e4ea)
       20    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16e6b2)
       19    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16eb12)
       19    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16eb9b)
       18    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16ea65)
       18    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16eb5e)
       16    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x16ea0f)
       15    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16e3f9)
       15    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16ebf0)
       15    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16ec42)
       15    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16ecc1)
       12    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16eac6)
       12    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16ed0c)
       12    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x16be64)
       11    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16ec87)
        8    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16e4b1)
        7    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x16e8ec)
        5    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x16e8f2)
        3    0.0%  com.apple.SwiftUI.AsyncRenderer (0x16e4d7)
        2    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x16e449)
        1    0.0%  ANEServicesThread (0x155608)
        1    0.0%  ANEServicesThread (0x15560c)
        1    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x16e4c2)

Signposts (subsystem ro.SimpleKube.AMSMB2): 49923 rows, 7462 rows from other subsystems ignored
  TransportRead    count 6207, bytes 106170403, size min 72 / median 14480 / p95 28960 / max 262144
  InboundChunk     count 6207, bytes 106170403, size min 72 / median 14480 / p95 28960 / max 262144
  RecvDrain        count 12681, bytes 106170403, copied 6474, EOF 0, would-block 6207, size min 4 / median 14480 / p95 28960 / max 262144
  ServiceDispatch  count 6207, duration ms min 0.007 / median 0.013 / p95 0.026 / max 1.552, unpaired 0
  ServicePass      count 6207, non-terminal 6207, terminal 0, duration ms min 0.005 / median 0.011 / p95 0.032 / max 0.481, unpaired 0
  coalescing ratio: 1.00 (6207 TransportRead / 6207 InboundChunk)
  reads per chunk: 1 read x6207
  zero-byte TransportRead skipped: 0
  pump-hop latency ms: min 0.008 / median 0.016 / p95 0.031 / max 0.372 (6207 pairs, 0 pairing errors)
  buffered at end: 0 bytes (InboundChunk 106170403 - RecvDrain 106170403)
  throughput: 0.683 MB/s (RecvDrain 106170403 bytes over 155.477 s)
  active throughput: 54.610 MB/s (RecvDrain 106170403 bytes over 1.944 s active; idle gaps > 1 s excluded)
```

Stalls observed: none in any run (no freeze, spinner or audio drop).

The other two runs, for spread (both are partial windows of a fill of a >1 GB file: run 1
attached while a fill was already running and caught its last 8.5 s; in run 3 the file was
opened 225 s into the 240 s window, so it caught the first 16 s). Per-event metrics are
comparable across all three; byte totals are not.

| Metric | Run 1 | Run 2 (median) | Run 3 |
|---|---|---|---|
| Bytes drained | 420 MB | 106 MB | 357 MB |
| Active throughput | 49.4 MB/s | 54.6 MB/s | 21.9 MB/s |
| Coalescing ratio | 1.00 | 1.00 | 1.01 (groups up to 19 reads) |
| Pump-hop latency median / p95 / max (ms) | 0.017 / 0.042 / 8.785 | 0.016 / 0.031 / 0.372 | 0.017 / 0.046 / 5.842 |
| Dispatch latency median / p95 (ms) | 0.013 / 0.032 | 0.013 / 0.026 | 0.013 / 0.036 |
| Service pass median / p95 (ms) | 0.012 / 0.039 | 0.011 / 0.032 | 0.010 / 0.040 |
| Chunk size median / p95 (bytes) | 14480 / 37648 | 14480 / 28960 | 17376 / 23308 |
| Main thread share of samples | 28.5% | 17.0% | 10.8% |
| Largest cooperative-pool thread share | 10.4% | 11.3% | 8.8% |

Reading: at 20–55 MB/s the inbound pump keeps up with the network (coalescing ratio 1.00–1.01,
pump-hop median 17 µs, dispatch median 13 µs, pass median 10–12 µs). The hop that #45 removes
costs tens of microseconds per chunk on this device; the cooperative-pool threads share the
per-thread table with the main thread but no single one dominates. Run 1's recording reported
`2 log/signpost messages lost due to high rates` (xctrace's own warning), which is the source
of its one unpaired pass and its 21120-vs-21119 read/chunk counts. Bundles are kept locally in
`../RandomPlayer/profiling/` (gitignored); the summaries above are the record.

## Using the baseline

For #45, #46, or any other change to the inbound path:

1. Same device, same server and link, uncached videos of comparable size, three runs, report the median.
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
