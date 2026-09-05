## Context

See proposal.md — Why. Facts the approach rests on, verified on 2026-09-05:

- The value under test is one literal, `.channelOption(NIOTSChannelOptions.maximumReceiveLength,
  value: 1 << 18)` at `AMSMB2/TCPTransportApple.swift:251`, inside the connection bootstrap.
  `minimumIncompleteReceiveLength` is left at its default of 1 and stays out of scope (#46).
- The rc5 After run (`docs/PROFILING.md`, run 3) shows `InboundChunk` median 14480 / p95 28960 /
  max 262144 bytes: ten and twenty 1448-byte TCP segments, with the cap reached only in the tail.
  With the minimum at 1 the receive completes as soon as the socket has data, so the cap binds
  only when the kernel has queued more than the cap between callbacks. The prior is therefore
  that the sweep moves only the max column; the design must be able to show "no separation"
  cheaply, not only "value X wins".
- RandomPlayer's fill (source at `07630053`): `ProgressiveDownloadService` runs one sequential
  loop per file; each sub-read is `max(256 KB, min(2 MB, 2 s × last measured throughput))` and
  goes through `SMBFileShareClient.readRange`, which issues one `pread` when the sub-read fits
  the handle's `maxReadSize` and otherwise `PipelinedRangeReader` at depth 4 with chunks of
  `maxReadSize`. Downloads self-limit to `maxConcurrentDownloads` (default 3, clamped 1–5) over
  a pool sized `maxConcurrentDownloads + 5`; previews use the reserve, which is where the rc5
  runs' 9–13 delivery threads came from.
- Tooling on the Mac: Xcode 26.6 (tvOS 26.5 SDK), `xctrace` 16.0, the Apple TV "Birou"
  (coredevice `6622E6DA-…`, xctrace UDID `00008110-00092DC90105401E`) listed as paired and
  online by both `devicectl` and `xctrace list devices`, a development identity for team
  `R5M272RLA9`. No `xcodegen`/`tuist`. The share `//win2k22.kaveman.intra/Share` holds one file
  over 1 GB (`deep-massages_1080p.mp4`, 1 103 993 961 bytes). Server and Apple TV are on
  `192.168.20.0/24`, so the tvOS local-network alert will fire for a new bundle identifier.
- `xcrun devicectl device process launch --console` streams the launched app's stdout to the
  Mac; `--attach <pid>` is the recording form the profiling document has proven on this device.

## Goals / Non-Goals

**Goals:**

- One command runs the whole sweep unattended after the first local-network approval, and the
  per-run artefacts (bundle, summary, harness log) are enough to re-derive every number.
- The harness's read pattern is traceable line-by-line to the RandomPlayer source it copies,
  so a reader can judge what the sweep does and does not represent.
- The two acceptance criteria the signposts cannot cover (small-PDU latency, memory high-water
  mark) are measured by the harness itself with the same run/median discipline.
- The library's production code is untouched by the tooling; the only library edit is the
  literal, and only if the measurement says so.

**Non-Goals:**

- A general benchmarking framework, a runtime override for the receive length, or any new
  library API. The harness is profiling tooling, not a product.
- Reproducing RandomPlayer's preview traffic, cache, seeks or UI. The anchor comparison against
  the rc5 After run is what says how far the harness is from the app.
- Tuning `minimumIncompleteReceiveLength`, QUIC, or any other transport knob.
- Extending `scripts/profile-summary.sh`. Its output is consumed as is.

## Decisions

**D1 — The harness is a tvOS app in this repository, with a hand-written Xcode project.**
`Profiling/ReceiveLengthHarness/ReceiveLengthHarness.xcodeproj` (objectVersion 60+, one app
target, `XCLocalSwiftPackageReference` to `../..` for the dynamic `AMSMB2` product, automatic
signing, `DEVELOPMENT_TEAM = R5M272RLA9`, bundle id `ro.SimpleKube.AMSMB2.ReceiveLengthHarness`,
`NSLocalNetworkUsageDescription` in the Info.plist). *Why:* an Apple TV needs an app bundle,
SwiftPM cannot produce one, and a checked-in project keeps the next re-profile independent of
RandomPlayer. *Alternatives:* generate the project with `xcodegen` (not installed; a new
operator dependency for a 200-line pbxproj); reuse RandomPlayer's bundle identifier to inherit
its local-network grant (rejected: installing it would replace the user's app on the device);
build the harness inside the RandomPlayer repository (rejected: the point is independence).

**D2 — Pure logic lives in a local SwiftPM package with `swift test`; the app is a thin shell.**
`Profiling/ReceiveLengthHarness/HarnessCore/` is a library package with the fill planner
(adaptive sub-read sizing and pipelined chunking, mirroring `ProgressiveDownloadService` and
`readRange`), the argument parser, the latency/memory sample percentiles and the summary-line
encoder; its tests run on macOS with `swift test --disable-sandbox --package-path
Profiling/ReceiveLengthHarness/HarnessCore`. The app target links `HarnessCore` and `AMSMB2`
and only wires the planner to `SMB2FileHandle.pread`, the probe to `attributesOfItem`, and
the sampler to `task_info`. *Why:* the repository's TDD rule applies to the harness and
simulator-hosted XCTest targets in a hand-written project are far more fragile than a package
test. *Alternative:* a tvOS-simulator unit-test target (rejected for the reason above).

**D3 — Workload parameters and their defaults.** Launch arguments: `--server`, `--share`,
`--user`, `--password`, `--path`, `--connections N` (default 3, RandomPlayer's default
`maxConcurrentDownloads`), `--start-delay S` (default 20), `--max-bytes B` per connection
(default: the whole file), `--probe-interval` (default 1 s), `--connect-retry` (default 5 s,
for the first-run local-network alert). Per connection: open the file once, then the sequential
sub-read loop with the RandomPlayer constants (256 KB floor, 2 MB cap, 2 s target, cold start
at the floor), each sub-read as one `pread` if it fits `maxReadSize`, else pipelined at depth 4;
every connection reads the same file from offset 0. The harness logs the negotiated
`maxReadSize` because a Windows server may grant more than the ~1 MB the issue assumes.
*Why N = 3:* it is the app's steady-state download concurrency; the preview reserve is
transient and unrelated to the knob. The anchor comparison (D8) measures the consequence.
*Alternative:* N = 10 to match the rc5 delivery-thread count (rejected: reproduces a symptom,
not the pattern; noted as an optional extra run in tasks if the anchor disagrees badly).

**D4 — The sweep varies the value by rewriting the literal and rebuilding.** The script
refuses to start if `AMSMB2/TCPTransportApple.swift` has uncommitted changes, rewrites the
`value: 1 << 18` expression with `sed` to the candidate (as `1 << k` when the value is a power of
two, else the integer), builds with
`xcodebuild -project … -scheme ReceiveLengthHarness -configuration Release
-destination 'id=<coredevice-id>' -allowProvisioningUpdates -derivedDataPath <scratch>`, and
restores the file from git in an `EXIT` trap. *Why:* a runtime override would add a production
code path to the transport for a one-off sweep. *Alternative:* an environment-variable read in
the transport (rejected, as above).

**D5 — Launch, attach, run, stop.** Per run: `devicectl device install app`, then
`devicectl device process launch --console --terminate-existing <bundle-id> -- <args>` in the
background with stdout to `<run>.log`; poll `devicectl device info processes` for the pid;
`xcrun xctrace record --device <udid> --instrument 'Time Profiler' --instrument os_signpost
--time-limit <T> --output <run>.trace --attach <pid>` in the background; the harness waits
`--start-delay` and then fills; when the harness prints its `HARNESS-DONE` line the script
sends `SIGINT` to `xctrace` and waits for the bundle to be written, falling back to the time
limit. `T` defaults to 4 min, the value the document uses. *Why the delay:* the document's
"attach while idle" step, so no chunk precedes the attach. *Risk:* whether `xctrace` saves
on `SIGINT` in the attach form is unverified on this device; the smoke run checks it, and the
time limit is the fallback either way.

**D6 — Harness-side measurements.** Small-PDU probe: a dedicated connection calls
`attributesOfItem(atPath:)` on the file every `--probe-interval`; the harness records each
round-trip and reports count, median, p95 and max. It is a proxy (CREATE/QUERY_INFO/CLOSE,
three small PDUs on a lightly loaded connection sharing the link), and the record says so.
Memory: `task_info(TASK_VM_INFO)` `phys_footprint` sampled every second from a timer; the
harness reports the peak and the value before the fill started. Both go into a single final
`HARNESS-SUMMARY {json}` line together with bytes read per connection, wall time, active
throughput, `maxReadSize`, and the argument echo (password redacted).

**D7 — Aggregation and the fixture.** `scripts/profile-sweep.sh` embeds a python program
(same pattern as `profile-summary.sh`) with a `--aggregate <dir>` mode that reads each run's
`summary.txt` (the `profile-summary.sh` output) and `harness.json`, picks the median run per
value by `ServicePass` median, and prints one plain-text table per value plus the delta table
against the reference row it is given. A hand-written fixture under
`test-fixtures/profiling/sweep-aggregate/` (three synthetic runs for two values, `expected.txt`)
pins its arithmetic; that is the Red test before the script exists.

**D8 — Decision rule, fixed before the numbers exist.** Reference row: the harness's own three
256 KB runs — not the rc5 After run. For a metric `m`, `spread(m)` is `max − min` of `m`'s
per-run medians across those three runs: the harness's own run-to-run noise, measured on the
same workload, file, server, link and connection count as every candidate. A candidate value
replaces 256 KB only if, for **both** `ServiceDispatch` and `ServicePass`, its median run
improves on the 256 KB median run by strictly more than `spread` of that metric, **and** probe
p95, memory peak and active throughput do not regress.

The rc5 run-to-run figures (dispatch medians 0.026 / 0.014 / 0.014 ms, pass medians 0.016 /
0.008 / 0.009 ms) are **not** the threshold. They were measured on a different workload, file,
server and connection count; they include the run-1 outlier the After section explicitly flags;
and read as a threshold they are unsatisfiable in either reading — as a range, "improve by more
than 0.014–0.026 ms" from a 0.014 ms median needs a negative median; as a width, 0.012 ms
dispatch is 86% of the median itself. They are reported for context only.

Anchor (a **reporting** requirement, not a gate): the harness's 256 KB median run is compared
with the rc5 After median run on *workload-shape* metrics only — `InboundChunk` size median /
p95 / max and the at-cap share (D7), coalescing ratio, delivery-thread count against
`--connections`, and active throughput. `ServiceDispatch` and `ServicePass` are the metrics
under test and are deliberately excluded: a harness tuned until it matched them would be
assuming the answer. The record states the distance on each shape metric and names the known
divergences (no cache write, one file, N = 3, Windows server) so a reader can judge the
transfer.

Sweep order: 64 KB, 256 KB, 1 MB; 128 KB and 512 KB only if the three separate on the rule.
Otherwise 256 KB stays and the record states the at-cap share that explains why the cap does
not bind at this workload.

**D9 — Where results live.** Bundles and logs under `../RandomPlayer/profiling/` are already
gitignored there; the sweep writes to a directory the operator names (default
`Profiling/runs/`, added to `.gitignore`). The record in `docs/PROFILING.md` is the artefact;
it carries the same context rows as the After section plus the server (Windows Server 2022,
not the Samba host of the rc4/rc5 runs — a stated confound), the file name and size, harness
arguments, and the AMSMB2 commit.

## Risks / Trade-offs

- [tvOS local-network alert blocks the first connect] → the harness retries the connect on an
  interval and the smoke run's instructions say to press Allow once; after that the grant
  persists for the bundle identifier.
- [`xctrace` attach fails or `SIGINT` does not save the bundle] → the script retries the attach
  once with a fresh pid lookup (the document records the same flake), and the time limit
  guarantees a bundle; the smoke run validates the stop path before any real run.
- [Signing needs an interactive Apple ID session] → `-allowProvisioningUpdates` with the
  account already signed into Xcode on this Mac; if it fails the script exits with the
  `xcodebuild` message and the operator opens Xcode once.
- [Windows server grants a larger max-read than Samba] → logged by the harness and recorded;
  it changes the pipelining shape, not the receive-cap question, and is part of the stated
  confound in D9.
- [The harness workload differs from the app's] → the anchor comparison in D8 is mandatory in
  the record; if it fails, the sweep is still valid relative to its own 256 KB row.
- [The fill is short] → 1.1 GB × 3 connections is about a minute at the rc5 link rate; inside
  the 4 min limit and long enough for tens of thousands of chunks per run.
- [A 1 MB cap raises per-connection buffering] → the memory row exists for this; the rule in
  D8 treats a memory regression as disqualifying.

## Migration Plan

Nothing to deploy. If the literal changes, it ships in the next release candidate with the
comment citing the record; rollback is reverting the literal.

## Open Questions

None that change the specs or tasks. Whether 128 KB and 512 KB are run is decided by the
D8 rule after the first three values.

## Pre-check on the rc5 bundles (Review Round 1, finding 1)

Run on 2026-09-05 against `../RandomPlayer/profiling/rc5-run{1,2,3}.trace` (the After
captures, 6.0.0-rc5, cap = 256 KB), `os-signpost` table exported with `xcrun xctrace export`,
`InboundChunk` sizes of subsystem `ro.SimpleKube.AMSMB2` histogrammed against the sweep bounds.
Since #45 every `TransportRead` is one `InboundChunk`, so the cap is the ceiling of this
distribution and the table bounds what any cap in [64 KB, 1 MB] can change.

| | Run 1 (outlier) | Run 2 | Run 3 (median) |
|---|---|---|---|
| Chunks / bytes | 15 142 / 399 MB | 19 709 / 364 MB | 26 494 / 491 MB |
| Median / p95 / p99 / p99.9 (bytes) | 15 928 / 92 672 / 218 788 / 262 144 | 14 480 / 27 512 / 60 816 / 262 144 | 14 480 / 28 960 / 66 608 / 262 144 |
| Chunks at the cap (262 144) | 65 = 0.43 % (4.3 % of bytes) | 65 = 0.33 % (4.7 % of bytes) | 65 = 0.25 % (3.5 % of bytes) |
| Chunks ≥ 128 KB | 3.07 % (22.7 % of bytes) | 0.50 % (6.3 % of bytes) | 0.50 % (5.9 % of bytes) |
| Chunks ≥ 64 KB | 7.55 % (38.3 % of bytes) | 0.87 % (8.2 % of bytes) | 1.00 % (8.4 % of bytes) |
| Extra chunks if cap = 128 KB (split at the cap) | +465 (+3.1 %) | +98 (+0.5 %) | +133 (+0.5 %) |
| Extra chunks if cap = 64 KB | +1 819 (+12.0 %) | +345 (+1.8 %) | +482 (+1.8 %) |
| Chunks that are exact multiples of 1448 (one TCP segment) | 86 % | 98 % | 98 % |

The 65 at-cap chunks per run are spread across the run (first at 0.1–0.4 s, last at 6.5–10.7 s)
and across 9–13 delivery threads, i.e. they are the fill's genuine tail, not one phase.

Reading, with the rc5 per-chunk chain of 25 µs median (hop + dispatch + pass):

- **Raising the cap** (512 KB, 1 MB) can only merge the 65 at-cap chunks: at best −48 chunks
  per run out of 15–26 thousand, under 0.4 % of the op count, about −1 ms of chain time over
  an 8.5 s run. Not measurable against the rc5 run-to-run spread.
- **Lowering the cap** costs +0.5 % (128 KB) to +1.8 % (64 KB) more chunks on the two clean
  runs and +3 % / +12 % on the outlier run, i.e. +3 ms to +12 ms of chain time per clean run.
  A regression, small, and larger exactly when the link is busiest.
- The distribution is set by the TCP segment cadence (98 % of chunks are whole segments,
  median ten segments) and the receive minimum of 1, not by the cap. No cap in the range
  changes the median or p95.

Conclusion: the rc5 bundles already answer #46 — keep 256 KB; the cap does not bind at this
workload beyond 0.25–0.43 % of chunks, raising it has no headroom, lowering it only costs. The
harness sweep in this change would measure a difference bounded above at a fraction of a
percent of op count, below the noise floor the procedure itself documents. The author's
recommendation is to re-scope this change to the record (this table, the reading, the
decision, and the at-cap share as a saturation metric) in `docs/PROFILING.md` and close #46,
and to keep the harness as a separate, optional change if a future workload needs an
unattended re-profile. The rewrite awaits the user's decision.
