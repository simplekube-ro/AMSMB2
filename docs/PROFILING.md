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

The inbound path has one executor hop per burst since the inbound push-conversion (#45): the
transport delivers each chunk into the bridge's store inside its own network callback, and the
inbound-ready signal then hops to `eventLoopQueue`. Before the conversion there were two — a
cooperative-pool pump `Task` sat between the transport and the store, and the Baseline section
below was captured with it. The signposts measure both:

| Metric | Source | Definition |
|---|---|---|
| Per-thread CPU | `time-profile` | Samples per thread and share of total. The unnamed `RandomPlayer (0x…)` threads are the Swift cooperative pool; `NIO-SGLTN-*` is the NIOTS event loop; the cooperative-pool share is the signature #45 should shrink. |
| `TransportRead` | event, bytes | One per chunk the TCP transport receives on the network stack's queue. **TCP transport only** — a QUIC capture has none, and the script prints `n/a` for the two derived metrics instead of pairing errors. |
| `InboundChunk` | event, bytes | One per non-empty chunk the bridge appends to its FIFO. Total `InboundChunk` bytes equal total `TransportRead` bytes: coalescing changes counts, never bytes. |
| Coalescing ratio | derived | `TransportRead` count ÷ `InboundChunk` count, plus the reads-per-chunk distribution. After #45 it is **1.00 by construction for the connection's lifetime**: the transport hands each read to the bridge inside the same callback, and a zero-length read is skipped before `TransportRead` is emitted, so every read has exactly one non-empty chunk to pair with. The one exception is a read that races bridge teardown — the bridge is closed but `transport.close()` has not run yet, so the channel can still read for a moment and the bridge drops the delivery — which leaves that read unpaired; expect at most a couple per connection, at the end. A ratio above 1 is otherwise only possible in a pre-#45 capture, where it was direct evidence of pump backlog. |
| Pump-hop latency | derived | For each `InboundChunk` the script pops `TransportRead`s in FIFO order until their bytes sum to the chunk size and reports chunk time − first popped read time. After #45 this is the residual **in-callback hand-off** — the bridge lock and the FIFO append, with the `Data` copy already done before `TransportRead` — not an executor hop. In the pre-#45 Baseline it is the network-queue → cooperative-pool hop that the conversion removed, which is what the before/after delta reads. |
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
| RandomPlayer commit | 92726906, pinned to AMSMB2 6.0.0-rc4 (simplekube-ro/RandomPlayer#549) |
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

## After (inbound push-conversion)

Captured 2026-09-05 with the inbound push-conversion (#45, PR #67) by the same procedure on the
same Apple TV, three runs, median run reported (median by `ServicePass` median duration: run 2
0.008 ms, **run 3 0.009 ms**, run 1 0.016 ms).

| Field | Value |
|---|---|
| Date | 2026-09-05 |
| Device / OS | Apple TV 4K (3rd generation) "Birou", tvOS 26.6, network-connected |
| AMSMB2 version | 6.0.0-rc5 (ff39d15) |
| RandomPlayer commit | 2949293e, pinned to AMSMB2 6.0.0-rc5 (simplekube-ro/RandomPlayer#550) |
| `xcrun xctrace version` | xctrace version 16.0 (17F113), Xcode 26.6 |
| Video | `892bjd1_1080_8000.mp4` (491 MB, complete fill) |
| Instruments | Time Profiler + os_signpost, attached to the running app, no debugger library in the process list |
| Runs | 3 (median reported) |

Script output of the median run (run 3):

```
Time profile: 87282 samples
  samples   share  thread
    17733   20.3%  Main Thread (0x193b6f)
    10264   11.8%  RandomPlayer (0x1a1263)
     7106    8.1%  RandomPlayer (0x1a1cae)
     6302    7.2%  RandomPlayer (0x1a12f3)
     5487    6.3%  RandomPlayer (0x1a1213)
     5081    5.8%  RandomPlayer (0x1a0faa)
     4310    4.9%  RandomPlayer (0x1a114c)
     3419    3.9%  RandomPlayer (0x1a0fa8)
     3403    3.9%  RandomPlayer (0x1a1cad)
     3345    3.8%  RandomPlayer (0x1a1b23)
     3220    3.7%  RandomPlayer (0x1a16bf)
     3137    3.6%  RandomPlayer (0x1a12f5)
     2183    2.5%  RandomPlayer (0x1a12f4)
     1744    2.0%  RandomPlayer (0x1a1e76)
     1489    1.7%  RandomPlayer (0x1a12b1)
     1434    1.6%  RandomPlayer (0x1a1fac)
     1314    1.5%  RandomPlayer (0x1a1df2)
     1265    1.4%  RandomPlayer (0x1a1fb7)
     1143    1.3%  RandomPlayer (0x1a1e77)
      914    1.0%  RandomPlayer (0x1a1faa)
      772    0.9%  RandomPlayer (0x1a1c5b)
      546    0.6%  RandomPlayer (0x1a1fab)
      376    0.4%  RandomPlayer (0x1a1fb0)
      362    0.4%  com.apple.SwiftUI.AsyncRenderer (0x1a1e61)
      174    0.2%  com.apple.SwiftUI.AsyncRenderer (0x1a1d2a)
      158    0.2%  com.apple.uikit.eventfetch-thread (0x193bb4)
       76    0.1%  RandomPlayer (0x1a10b2)
       55    0.1%  RandomPlayer (0x1a1b22)
       43    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a18e7)
       40    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1e6c)
       34    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1fdf)
       28    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1c7c)
       27    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1d31)
       25    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1d94)
       22    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1ed2)
       21    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1bfb)
       21    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a11e1)
       19    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1f29)
       17    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1279)
       17    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1c31)
       14    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1dd9)
       12    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1b97)
       12    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a2040)
       11    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a14e6)
       11    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1b21)
       11    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1cd4)
        9    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a12f6)
        9    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1e38)
        8    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a15fe)
        8    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1747)
        7    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a202d)
        7    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1c81)
        6    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1db2)
        6    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1d67)
        6    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1e86)
        5    0.0%  com.apple.SwiftUI.AsyncRenderer (0x1a1ba1)
        4    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1f88)
        3    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a110f)
        2    0.0%  RandomPlayer (0x1a1df1)
        2    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1a58)
        1    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1a56)
        1    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a1b9f)
        1    0.0%  com.apple.coremedia.sharedRootQueue.47 (0x1a2031)

Signposts (subsystem ro.SimpleKube.AMSMB2): 213141 rows, 2826 rows from other subsystems ignored
  TransportRead    count 26494, bytes 491356162, size min 72 / median 14480 / p95 28960 / max 262144
  InboundChunk     count 26494, bytes 491356162, size min 72 / median 14480 / p95 28960 / max 262144
  RecvDrain        count 54203, bytes 491377882, copied 27715, EOF 0, would-block 26488, size min 4 / median 14480 / p95 28960 / max 262144
  ServiceDispatch  count 26487, duration ms min 0.003 / median 0.014 / p95 0.038 / max 1.460, unpaired 0
  ServicePass      count 26488, non-terminal 26488, terminal 0, duration ms min 0.002 / median 0.009 / p95 0.035 / max 7.491, unpaired 0
  coalescing ratio: 1.00 (26494 TransportRead / 26494 InboundChunk)
  reads per chunk: 1 read x26494
  zero-byte TransportRead skipped: 0
  pump-hop latency ms: min 0.001 / median 0.002 / p95 0.007 / max 2.078 (26494 pairs, 0 pairing errors)
  buffered at end: -21720 bytes (InboundChunk 491356162 - RecvDrain 491377882)
  throughput: 57.963 MB/s (RecvDrain 491377882 bytes over 8.477 s)
  active throughput: 57.963 MB/s (RecvDrain 491377882 bytes over 8.477 s active; idle gaps > 1 s excluded)
```

Stalls observed: none in any run (no freeze, spinner or audio drop).

The other two runs, for spread. All three are complete fills captured inside the window; run 1
(`GP2449_Sara_diamante.mp4`, 399 MB) ran at 35 MB/s over 13 concurrent connections with p95
chunks three times the size of the other runs', and is the worst of the three on every per-event
row — it is recorded as captured, and the median rule keeps it from setting the number. The
operator did not note run 2's file name.

| Metric | Run 1 | Run 2 | Run 3 (median) |
|---|---|---|---|
| Bytes drained | 399 MB | 364 MB | 491 MB |
| Active throughput | 35.3 MB/s | 63.0 MB/s | 58.0 MB/s |
| Connections (threads emitting `TransportRead`) | 13 | 9 | 10 |
| Coalescing ratio | 1.00 | 1.00 | 1.00 |
| Pump-hop latency median / p95 / max (ms), per-thread pairing | 0.002 / 0.012 / 5.551 | 0.002 / 0.008 / 0.578 | 0.002 / 0.007 / 2.078 |
| Dispatch latency median / p95 (ms) | 0.026 / 0.104 | 0.014 / 0.040 | 0.014 / 0.038 |
| Service pass median / p95 (ms) | 0.016 / 0.090 | 0.008 / 0.036 | 0.009 / 0.035 |
| Chunk size median / p95 (bytes) | 15928 / 92672 | 14480 / 27512 | 14480 / 28960 |
| Main thread share of samples | 19.5% | 42.0% | 20.3% |
| Largest unnamed-thread share | 4.8% | 9.5% | 11.8% |
| Global-FIFO pairing errors reported by the script | 155 | 1 | 0 |

Delta against the Baseline (same script, same procedure, median run against median run). The
merge condition was no regression in the dispatch/pass percentiles or active throughput, and no
stalls.

| Metric | Baseline (rc4, run 2) | After (rc5, run 3) | Delta |
|---|---|---|---|
| Per-thread shares: main / largest unnamed / next three | 17.0% / 11.3% / 7.4%, 7.0%, 6.1% | 20.3% / 11.8% / 8.1%, 7.2%, 6.3% | no visible collapse — see reading |
| `ServiceDispatch` median / p95 / max (ms) | 0.013 / 0.026 / 1.552 | 0.014 / 0.038 / 1.460 | +0.001 / +0.012 / −0.092 |
| `ServicePass` median / p95 / max (ms) | 0.011 / 0.032 / 0.481 | 0.009 / 0.035 / 7.491 | −18% / +0.003 / one 7.5 ms pass |
| Active throughput (MB/s) | 54.6 | 58.0 | +6% (link-bound) |
| Stalls | none | none | — |
| Pump-hop latency median / p95 / max (ms) — residual | 0.016 / 0.031 / 0.372 | 0.002 / 0.007 / 2.078 | −87% / −77% / +1.7 |
| Coalescing ratio | 1.00 | 1.00 (by construction) | — |
| Per-chunk chain, hop + dispatch + pass medians (µs) | 16 + 13 + 11 = 40 | 2 + 14 + 9 = 25 | −38% |

Reading:

- The hop is gone. The `TransportRead → InboundChunk` hand-off fell from a 16 µs median to
  2 µs (the bridge lock and the append), and in every rc5 run the set of threads emitting
  `InboundChunk` is exactly the set emitting `TransportRead` (13 = 13, 9 = 9, 10 = 10): the
  chunk never touches a thread other than the one the network delivered it on. In the baseline
  the chunk was appended from the pump task.
- The per-thread table does not show the collapse the issue expected, and it cannot: on Apple
  platforms the Swift cooperative pool and the NIOTS event loops are both Dispatch worker
  threads, so the unnamed `RandomPlayer (0x…)` rows were never a pool-only signature. In the
  baseline, 12 of the 13 threads that appended chunks were also threads that read from the
  network. The thread sets from the signposts, not the sample shares, are the structural
  evidence.
- Dispatch median is unchanged within the baseline's own run-to-run spread (0.013 in all three
  baseline runs; 0.014 in the two clean rc5 runs). Dispatch p95 is 2 µs above the baseline's
  worst run (0.038 vs 0.026–0.036). Pass median is 18% lower; pass p95 is inside the baseline
  range (0.032–0.040). Active throughput is link-bound and unchanged. The chain from network
  delivery to the end of the drain shortened from about 40 µs to 25 µs per chunk at the median.
- Run 1 is an outlier on every per-event row (dispatch 0.026 / 0.104, pass 0.016 / 0.090) with
  13 concurrent connections, three-times-larger p95 chunks and the lowest link throughput; the
  two clean runs and the median run do not reproduce it. It is the run to re-check if #46 or a
  later change sees a similar shape.

Procedure notes from this capture:

- RandomPlayer starts a fill as soon as it is launched, so the "attach while idle" step means:
  launch, wait for that first fill to finish (or navigate to the browse screen), then attach.
  The 15 s pre-run attach here caught 463 MB of that launch fill.
- `xcrun xctrace record --attach <pid>` failed once with `Cannot find process for provided pid`
  for a pid that `devicectl device info processes` had just listed; the identical command a
  minute later attached. Retry before falling back to `--attach RandomPlayer`.
- The script pairs `TransportRead` to `InboundChunk` in one global FIFO across all connections.
  RandomPlayer fills over 9–13 connections at once, so when two connections' reads interleave
  the global pairing reports overshoot/underflow pairs that are not real (run 1: 155; run 2: 1;
  run 3: 0). After the conversion every read and its chunk are on one thread, so pairing keyed
  by thread is exact: recomputed that way the three runs give 15141 / 19708 / 26494 pairs with
  at most one attach carry-over each and the same latency percentiles the script prints for
  run 3. Keying the script's pairing by thread is a follow-up; until then read the hop row from
  a run with zero reported errors, or recompute per thread.
- Attach carry-over as documented above: run 3's `buffered at end` is −21720 bytes (one chunk
  appended before the attach, drained inside it); runs 1 and 2 each have one `InboundChunk`
  whose `TransportRead` preceded the attach.

Bundles are kept locally in `../RandomPlayer/profiling/` as `rc5-run{1,2,3}.trace` (gitignored);
the summaries above are the record.

## Using the baseline

For #45, #46, or any other change to the inbound path:

1. Same device, same server and link, uncached videos of comparable size, three runs, report the median.
2. Run `scripts/profile-summary.sh` on each bundle; never read numbers off the Instruments GUI.
3. Compare against the Baseline (pre-#45) and After (post-#45) sections above. The evidence a PR
   must carry is the delta on the **per-thread shares** (the cooperative-pool threads called out
   — the signature #45 targets), the **`ServiceDispatch` and `ServicePass` percentiles**, the
   **active throughput**, and the **stalls**. Pump-hop latency and the coalescing ratio are no
   longer the comparison: post-conversion the ratio is 1.00 by construction and the pump-hop row
   is only the residual in-callback hand-off — report them, but read the delta from the four
   metrics above.
4. Record the new numbers under a dated subsection here when the change merges, so the next
   comparison has a baseline that matches the shipped code.

Faithfulness of an rc4 baseline to what PR #43 shipped (rc1): the inbound hot path is unchanged
between `6.0.0-rc1` and `6.0.0-rc3`, and rc4 adds only the signposts. Reproduce with:

```
git diff --stat 6.0.0-rc1..6.0.0-rc3 -- AMSMB2/TransportBridge.swift \
  AMSMB2/TCPTransportApple.swift AMSMB2/SMBTransport.swift      # empty
git diff 6.0.0-rc1..6.0.0-rc3 -- AMSMB2/Context.swift          # teardown/error paths only
```
