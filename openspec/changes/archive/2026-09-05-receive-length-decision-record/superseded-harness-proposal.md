## Why

[Issue #46](https://github.com/simplekube-ro/AMSMB2/issues/46) asks for a measured value of
`NIOTSChannelOptions.maximumReceiveLength` (set to 256 KB by PR #43 as a heuristic, at
`AMSMB2/TCPTransportApple.swift:251`), swept across candidate values against the rc5 "After"
numbers in `docs/PROFILING.md` (#68). Every gate is cleared — #44 baseline, #45 push-conversion
in `6.0.0-rc5`, #69 per-thread pairing — but the recorded procedure needs an operator on the
Siri Remote driving RandomPlayer through one uncached cache fill per run, and a sweep is five
values × three runs = fifteen fills plus one rebuild per value. That does not fit an unattended
loop, and RandomPlayer's fill is also more workload than the knob needs: its 9–13 concurrent
connections came from previews and the launch fill, not from the pattern under test.

This change makes the sweep self-driving: a throwaway tvOS harness app in this repository that
reproduces RandomPlayer's SMB read pattern from launch arguments, a script that rebuilds the
library at each candidate value, installs and launches the harness on the paired Apple TV,
attaches `xctrace`, and summarises the bundle with the existing `scripts/profile-summary.sh`,
and the measured recommendation for #46 recorded in `docs/PROFILING.md`. The one manual step
left is the tvOS local-network permission alert the first time the harness opens a socket.

## What Changes

- **A profiling harness app** under `Profiling/ReceiveLengthHarness/` (tvOS, Release, signed
  with the same development team as RandomPlayer, depending on this checkout of AMSMB2 by local
  package path). It reads server, share, credentials, file path, connection count and start
  delay from its launch arguments, waits for the delay so the recording can attach to an idle
  process, then runs RandomPlayer's fill pattern as read from its source at `07630053`: per
  connection one sequential loop of sub-reads (adaptive between a 256 KB floor and a 2 MB cap
  at a 2 s latency target), each sub-read issued as pipelined `pread`s of the negotiated
  max-read size at depth 4; N such fills run concurrently over their own connections. Alongside
  the fill it probes small-PDU latency (a metadata query once per second on a separate
  connection) and samples its own physical memory footprint once per second, and prints one
  machine-readable summary line at the end. No local cache, so one file serves every run.
- **A sweep script** `scripts/profile-sweep.sh` that, for each candidate value, rewrites the
  literal on the transport line, builds the harness for the device, installs and launches it
  with the run arguments, attaches the `xctrace` recording the profiling document prescribes,
  waits for the harness to finish, exports the bundle, runs `scripts/profile-summary.sh`, and
  collects the harness summary; it restores the literal when it exits. It also has a smoke mode
  (one short attach, the profiling document's pre-run check) and a bundle-only mode that
  re-summarises existing bundles.
- **The measurement** for #46: at least the values 64 KB, 256 KB and 1 MB, three runs each,
  median by `ServicePass` median, with 128 KB and 512 KB added only if those three separate.
  Recorded in `docs/PROFILING.md` as a dated subsection with the per-value table, the harness's
  256 KB run compared against the rc5 After run (chunk-size distribution, dispatch and pass
  percentiles, active throughput) to show the harness reproduces the app's shape, the
  small-PDU and memory rows the signposts cannot give, and the decision.
- **The literal itself** changes only if the sweep shows a value that beats 256 KB on the
  decision rule; then the comment on that line cites the subsection and the integration suite
  is re-run. Otherwise the code change is nil and the deliverable is the record.
- **Procedure addendum** in `docs/PROFILING.md`: how to run the harness sweep, and the
  statement that the harness workload is comparable to the RandomPlayer fill only through the
  anchor comparison above.

No public API change. No behaviour change on any library path unless the literal changes.

## Capabilities

### New Capabilities

- `receive-length-sweep`: an unattended, repeatable on-device sweep of the TCP transport's
  receive length — the harness workload, the sweep driver, and the recorded measurement with
  its decision rule.

### Modified Capabilities

<!-- none: the inbound-profiling capture procedure, its metrics and its summary script are
     unchanged; the harness is an additional workload for the same procedure and the sweep
     is recorded under it -->

## Impact

- New: `Profiling/ReceiveLengthHarness/` (Xcode project, app sources), `scripts/profile-sweep.sh`,
  test fixture(s) for the sweep script's aggregation, a dated subsection in `docs/PROFILING.md`.
- Possibly modified: `AMSMB2/TCPTransportApple.swift` line 251 and its comment.
- Operator prerequisites (not in the repo): the paired Apple TV "Birou" (tvOS 26.6), Xcode
  26.6 / `xctrace` 16.0, a development signing identity for team `R5M272RLA9`, the SMB server
  `win2k22.kaveman.intra` share `Share` holding one file of at least 1 GB. Credentials are
  passed as launch arguments only and never written to the repository or the bundle.
- The harness is a **dynamic** consumer of the AMSMB2 product, as the LGPL note requires.
- Closes #46 when the measurement is recorded and the decision applied.

## Review

### Round 1 (2026-09-05) — NEEDS REVISION

Reviewer: `project-architect`. Reviewed proposal.md, design.md,
`specs/receive-length-sweep/spec.md`, tasks.md against `docs/PROFILING.md`
(Workload / Metrics / After / Using the baseline), `scripts/profile-summary.sh`'s header,
`openspec/specs/inbound-profiling/spec.md`, `AMSMB2/TCPTransportApple.swift:251`, `Package.swift`,
`.gitignore`, `Makefile`, `.github/workflows/swift.yml`, and the RandomPlayer sources at
`07630053`.

**What is right.** The library's guarantees are preserved: no production code path is added, no
public API moves, `Package.swift` already declares `.library(name: "AMSMB2", type: .dynamic)` so a
harness consuming the product satisfies the LGPL dynamic-linking note, and the only possible
library edit is one literal plus its comment. The first/second/third-order trace is clean —
first order: the `maximumReceiveLength` literal; second order:
`InboundBufferingHandler.channelRead` chunk sizes → `TransportBridge.appendInbound` → inbound
FIFO depth → `RecvDrain` sizes, all inside the seam; third order: nothing reaches `RawBuffer` /
`bufferPool` (libsmb2's read side), the QUIC transport (no NIOTS channel option), Linux (no
`Network`), `NSSecureCoding`/`Codable`, or `ObjCCompat`. D4's rebuild-per-value over a runtime
override is the correct call and I endorse it without qualification: an env-var read in
`TCPTransportApple.connect` would be a permanent production branch bought for a one-off sweep.
The `HarnessCore` split (D2) is proportionate, not over-engineering — a package test is the only
way to satisfy the TDD rule without a simulator-hosted XCTest target in a hand-written pbxproj.
Verified for the change's benefit: RandomPlayer `Services/` is byte-identical between `2949293e`
(the commit the rc5 After run was captured against) and `07630053` (the commit the design cites),
so the citation is sound — state that in D-Context, it is load-bearing for the anchor.

**Findings.**

1. **[blocking — method] The design's own prior makes the sweep's discriminator unable to
   discriminate, and a decisive cheap pre-check was not considered.** D-Context concedes the cap
   binds only in the tail (rc5 run 3: `InboundChunk` median 14480, p95 28960, max 262144). Since
   #45 the coalescing ratio is 1.00 by construction, so `maximumReceiveLength` *is* the ceiling
   of the `InboundChunk` size distribution — which means the three rc5 bundles already kept at
   `../RandomPlayer/profiling/rc5-run{1,2,3}.trace` **bound the entire achievable effect of any
   cap in [64 KB, 1 MB], in both directions, with no new code and no device time**: the share of
   chunks ≥ 64 KB bounds what lowering the cap can do, and the share at exactly 262144 bounds
   what raising it can do. A ten-minute histogram over the `os-signpost.xml` those bundles
   already export answers #46 with a measured number. Add this as task 0, run it, and record the
   histogram in the change notes; then either (a) it shows a non-trivial at-cap share and the
   harness sweep proceeds with its scope justified, or (b) it shows ~0 and #46 closes on that
   number, with the harness built only if the repeatability is wanted for its own sake. Either
   way the histogram belongs in the `docs/PROFILING.md` record. This is CLAUDE.md working rule 2
   (simplicity first) applied to a change that currently spends a tvOS app, a hand-written
   pbxproj, a nested SwiftPM package and 9–15 device runs before establishing that there is an
   effect to measure.

2. **[blocking — fidelity] "No local cache" is not a simplification, it is the removal of the
   consumer-side backpressure the knob interacts with — and the proposal presents it as a
   feature.** Verified against `ProgressiveDownloadService.acceptSubRead` →
   `LocalFileCache.storeData` → `writePiece`: the app writes **every** accepted sub-read to a
   segmented, encrypted on-disk cache, with disk-space checks, on the same device, between
   sub-reads. That work is exactly what lets the kernel accumulate bytes between
   `NWConnection.receive` completions, and the cap binds *only* when it has. A harness that
   discards the data drains faster than the app, so it will show the cap binding **less** than
   the real workload — biasing the whole sweep toward the null result the design already
   predicts. Either give the harness a per-sub-read sink that writes to a scratch file
   (encryption may be omitted, and then named as a residual confound), or make the no-sink
   choice an explicit, argued decision with one A/B run at 256 KB (`--sink file` vs
   `--sink none`) quantifying the difference. Fix proposal.md's "No local cache, so one file
   serves every run" — the sentence conflates a run-hygiene benefit with a workload claim.

3. **[blocking — method] D8's threshold was unsatisfiable and drawn from the wrong population.
   Rewritten by me in design.md and spec.md.** "improve by more than the rc5 run-to-run spread
   (0.014–0.026 ms dispatch, 0.008–0.016 ms pass)" is unsatisfiable under either reading: as a
   range it asks a 0.014 ms median to improve by up to 0.026 ms; as a width it asks for a
   0.012 ms improvement on a 0.014 ms median (86%). It also sources the noise floor from a
   different workload, file, server and connection count, and includes the run-1 outlier the
   After section itself flags. I replaced it with the harness's own three-run spread at 256 KB
   (`max − min` of the per-run medians), which is measured on the same workload as every
   candidate. Review the replacement text in D8 and the mirrored sentence in the spec's
   "Recorded decision" requirement.

4. **[blocking — method] The anchor conflated workload shape with the outcome under test.
   Rewritten by me.** Requiring the harness's dispatch and pass medians to sit inside the rc5
   spread makes the experiment's *dependent variables* a comparability gate — a harness tuned
   until it matched them would be assuming the answer, and it would fail for reasons unrelated
   to comparability (Windows Server 2022 vs the Samba host, N = 3 vs 9–13, a different file and
   link). D8 and the spec now compare shape metrics only — chunk-size distribution and at-cap
   share, coalescing ratio, delivery threads vs `--connections`, active throughput — and the
   anchor is a reporting requirement, not a gate. Confirm you accept that framing.

5. **[blocking — instrumentation gap] There is no saturation metric, so "no separation" cannot
   be distinguished from "the cap never binds".** The decision rests on dispatch/pass medians,
   which D-Context predicts will not move; `min/median/p95/max` from `profile-summary.sh` gives
   one order statistic at the top and nothing about how often the ceiling is reached. Add an
   **at-cap share** (count and fraction of `InboundChunk` events within a stated epsilon of the
   candidate cap) per run. This needs no change to `profile-summary.sh` — which the design
   rightly makes a non-goal — because the script already accepts a *directory* holding
   `time-profile.xml` / `os-signpost.xml`. So: have the sweep export the two tables **once** into
   a persistent per-run directory, pass that directory to `profile-summary.sh`, and let the
   sweep's own python compute the at-cap share from the same `os-signpost.xml`. This also
   removes a duplicated ~200k-row export per run (the script currently re-exports into a temp
   dir it deletes). Update D6/D7, the "Unattended sweep" requirement and the aggregate scenario.

6. **[blocking — silent-failure guard] Nothing proves each candidate value actually reached the
   built binary.** If `xcodebuild` reuses a cached local-package build, or the `sed` rewrite
   silently misses (the literal is `1 << 18`, not a decimal — a candidate written as an integer
   changes the expression's *shape*, and a later restore-then-rewrite must match the rewritten
   form, not the committed one), the sweep measures the same binary N times and reports a
   perfect null with no signal that anything went wrong. Require per-run build provenance: the
   rewritten source line and the SHA-256 of the built `AMSMB2` binary written into each run
   directory, and an aggregate-mode assertion that the hashes are **identical within a value and
   distinct across values**. Add it to D4 and to the "Sweep produces one summarised bundle per
   run" scenario.

7. **[blocking — delta-spec completeness] `inbound-profiling` needs a MODIFIED delta.**
   `docs/PROFILING.md` is governed by that capability's "Release-build on-device capture
   procedure" requirement, which enumerates the document's contents and pins "the workload (one
   cache fill: the consumer app caches a video on open …)" as *the* workload; its "Baseline is
   recorded and discoverable" scenario names the receive-length sweep by name. This change adds
   a second workload and a "Harness sweep" procedure paragraph to that document, so
   "Modified Capabilities: none" is wrong. Add a MODIFIED delta for that requirement — a
   faithful full copy of the requirement text with only the intended edit — stating that the
   document also carries a harness workload for transport-knob sweeps, that a capture is
   labelled with which workload produced it, and that harness captures are compared to app
   captures only through the shape anchor. Then state the ownership boundary in the new spec's
   Purpose: `receive-length-sweep` owns the harness, the sweep driver and the sweep record;
   `inbound-profiling` continues to own the signposts, the app-workload procedure, the metrics
   and the summary script. Without the boundary the sweep spec's restatement of the instrument
   set ("exactly the Time Profiler and `os_signpost` instruments") silently drifts the day the
   procedure changes.

8. **[blocking — TDD] The `HarnessCore` tests are not reachable from any command this repository
   runs.** `Makefile` runs `swift test`, `.github/workflows/swift.yml` runs `swift test -v`, and
   neither passes `--package-path`; nothing else in `Makefile`, `scripts/` or `.github/` does. So
   D2 satisfies the TDD rule on paper while producing tests no CI run and no `make test` will
   ever execute — which is how a "Red then Green" package rots into dead code (CLAUDE.md, Dead
   Code Prevention). Either add a `make harnesstest` target and a CI step, or record explicitly
   in D2 and tasks that these tests are operator-run only and name what re-runs them. My
   recommendation is the Makefile target: it costs one line and keeps the fill planner honest
   the next time someone re-derives it from a newer RandomPlayer.

9. **[conditional — fidelity] Four verified divergences from the app that the harness must either
   reproduce or record.** All four are cheap to reproduce and each changes the socket-drain
   cadence, which is what the knob sees:
   (a) **Outer 2 MB chunk loop.** The sub-read `remaining` clamp is the tail of the current 2 MB
   chunk pulled from the cache gap tracker, not the tail of the file — so the pattern has a
   periodic short read at every 2 MB boundary. The design describes one flat loop over the whole
   file. (I corrected the spec scenario; correct D3 to match.)
   (b) **Task priority.** The app's fill runs on `Task(priority: .utility)`; the library's
   `eventLoopQueue` is `.userInitiated`. Cooperative-pool QoS affects the dispatch latency this
   change measures — the harness must use `.utility` for its fill tasks, and D3 must say so.
   (c) **Handle reuse.** `SMBFileShareClient` keeps a `FileHandleCache` (max 8) and reuses an
   open handle across range reads. D3's "open the file once per connection" matches this in
   effect — say so, so a reader does not think it is a divergence.
   (d) **Sliding-window pipeline, not batches.** `PipelinedRangeReader` seeds four tasks and
   refills one per completion, reassembling by index. The spec said "at most four at a time in
   order"; I corrected it. `readRange`'s single-`pread` threshold is `<=` `maxReadSize`.
   Also note in D3 that `chunkSize` (2 MB) and `subReadSize` (256 KB) are *parameter defaults*
   in `ProgressiveDownloadService`, not formula literals, and that the throughput estimate is the
   single last sub-read's rate with no smoothing — a harness that averages will pick different
   sub-read sizes.

10. **[conditional — credential hygiene] The password reaches the Mac's process table and
    `devicectl`'s own logging, which the design does not acknowledge.** The harness redacting its
    own echo (good, and consistent with the `credential-redaction` capability) does not help: the
    sweep script's `devicectl device process launch … -- --password <secret>` is visible to `ps`
    for the whole run. Require the sweep to read the password from an environment variable
    (`SMB_PASSWORD`, matching the integration suite's convention), to never run under `set -x`
    while the argument vector is built, and to state the residual `ps` exposure as a known
    limitation in the procedure paragraph. `*.log` is already globally gitignored, so
    `harness.log` is covered; task 3.4's `Profiling/runs/` entry still belongs there for the
    bundles.

11. **[conditional — tvOS/xctrace operational gaps].** Five things the design misses, all of
    which will cost a run each if they are met on the device rather than in the document:
    (a) **Sleep and the idle timer.** An unattended tvOS run with no remote input will hit
    *Settings ▸ General ▸ Sleep After*. Set `UIApplication.shared.isIdleTimerDisabled = true` in
    the harness and tell the operator to raise the sleep timeout; a device that sleeps mid-fill
    produces a truncated bundle that still passes every structural check.
    (b) **Never delete the harness between values.** `devicectl device install app` over an
    existing install preserves the local-network grant; deleting the app resets it and re-arms
    the alert D5's unattended loop cannot answer. The sweep must reinstall, never uninstall.
    (c) **`--console` is a different launch form than the one `docs/PROFILING.md` proved.** The
    document validated a plain `devicectl device process launch`. The smoke run must therefore
    run the process-list check specifically on a `--console` launch before nine runs depend on
    it, and the design should say that is why the check is in smoke mode.
    (d) **Killing the `devicectl --console` process may terminate the app.** D5 keeps it alive
    until `HARNESS-DONE`, which is right — make it explicit that this is a requirement, not an
    incidental ordering, and that `--terminate-existing` on the next launch is what cleans up.
    (e) **Embedding.** `AMSMB2` is a `.dynamic` product; a hand-written pbxproj needs the
    `XCSwiftPackageProductDependency` in *Link Binary With Libraries* **and** an embed-and-sign
    step, or the app dyld-faults at launch on the device with no build error. Name it in task 2.1
    so it is not discovered on the Apple TV.

12. **[conditional — scope] `--connections 10` deserves a decision, not a contingency.** D3 rejects
    N = 10 as "reproduces a symptom, not the pattern" and task 4.3 then makes it conditional on
    the anchor failing. But the rc5 delivery-thread count (9–13) is not a symptom of anything the
    harness controls — it is the app's preview reserve plus its download concurrency, and per-
    connection socket buffering is precisely what a receive-cap change scales with. Run one
    `--connections 10` set at 256 KB unconditionally as part of the shape anchor and report it;
    it is one extra set and it is the only evidence that N = 3 does not understate the cap's
    effect.

**Edits I made** (only inside this change directory):
- `design.md` — D8 replaced: the decision threshold is now the harness's own 256 KB three-run
  spread with the rc5 figures demoted to context, and the anchor is shape-metrics-only and
  explicitly a reporting requirement.
- `specs/receive-length-sweep/spec.md` — (i) the sub-read-planning scenario now states the 2 MB
  chunk `remaining` clamp, the unsmoothed last-measured throughput, and the four-outstanding
  sliding window reassembled in offset order; (ii) the "Recorded decision" requirement mirrors
  the new spread and shape-only anchor; (iii) added scenario "An interrupted run leaves the
  transport source unchanged" — the requirement said "SHALL restore the literal on any exit" with
  no scenario, and an un-restored literal is the one failure of this change that can reach a
  commit.

**Conditions to clear before `/opsx:apply`.** Findings 1–8 are blocking. Findings 9–12 must each
be either implemented or recorded as an argued decision in design.md; none may be dropped
silently. Finding 1 is the one to do first — its answer may shrink findings 2, 5, 6, 9 and 12 to
nothing, and it is the cheapest measurement in the change.

Re-gate: re-submit for `project-architect` review after revision. Per the precedent in
`archive/2026-09-05-profile-summary-per-thread-pairing`, record Round 2 below this section rather
than editing this one.

### Author response to Round 1 (2026-09-05)

Finding 1 was run first (design.md, "Pre-check on the rc5 bundles"): the existing rc5 bundles
bound the effect of any cap in [64 KB, 1 MB] to under 0.4 % of the chunk count upward and
+0.5–1.8 % downward on the clean runs. The author recommends re-scoping the change to a
docs-only record and closing #46 on that evidence; findings 2–12 apply only if the harness is
kept. Awaiting the user's decision before a Round 2 submission.
