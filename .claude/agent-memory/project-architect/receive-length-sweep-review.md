---
name: receive-length-sweep-review
description: issue #46 gate history (sweep harness, then the decision record that replaced it), plus verified RandomPlayer fill-pattern facts any AMSMB2 profiling workload must respect
metadata:
  type: project
---

`receive-length-sweep-harness` (issue #46, the `maximumReceiveLength` sweep) reviewed 2026-09-05
→ **NEEDS REVISION** (12 findings, 1–8 blocking). Gates #44/#45/#69 were all clear.

**Why it did not pass:** the method, not the tooling. Durable lessons:

- **The rc5 bundles already bound the answer.** Since #45 the coalescing ratio is 1.00 by
  construction, so `maximumReceiveLength` *is* the ceiling of the `InboundChunk` size
  distribution. A histogram over the `os-signpost.xml` of the three existing
  `../RandomPlayer/profiling/rc5-run{1,2,3}.trace` bundles bounds the whole achievable effect of
  any cap in [64 KB, 1 MB] — share ≥ 64 KB bounds lowering it, share at 262144 bounds raising it.
  Always look for this kind of pre-check before endorsing a device-time sweep.
- **`profile-summary.sh` accepts an export *directory*.** So a driver can export the two tables
  once into a persistent dir, pass the dir to the script, and compute extra metrics from the same
  `os-signpost.xml` — no need to extend the script (and it avoids a duplicated ~200k-row export
  per run, since the script otherwise re-exports into a temp dir it deletes).
- **Never source a decision threshold from a different workload's run-to-run spread.** The rc5
  App-workload spread includes the documented run-1 outlier and, read as a threshold, is
  unsatisfiable against its own median. Use the candidate harness's own three-run spread at the
  reference value.
- **Never make the metric under test part of the comparability anchor.** Anchor on workload
  *shape* (chunk-size distribution, at-cap share, coalescing ratio, delivery threads, active
  throughput); `ServiceDispatch`/`ServicePass` are the dependent variables.
- **A rewrite-the-literal-and-rebuild sweep needs build provenance** (rewritten line + SHA-256 of
  the built binary per run; identical within a value, distinct across values) or a cache hit
  silently reports a perfect null.

**Verified RandomPlayer facts (commit `07630053`; `Services/` byte-identical to `2949293e`, the
commit the rc5 After run was captured against — so either citation is sound):**

- `ProgressiveDownloadService` **writes every accepted sub-read to a segmented, encrypted on-disk
  cache** (`acceptSubRead` → `LocalFileCache.storeData` → `writePiece`). Any harness that discards
  data drains the socket faster than the app and will understate how often the receive cap binds.
  This is the single most important fidelity fact for AMSMB2 profiling workloads.
- Outer loop is over **2 MB chunks** from the cache gap tracker; the sub-read `remaining` clamp is
  the tail of that chunk, not of the file — a short read at every 2 MB boundary.
- Sub-read size = `min(max(min(T·2s, chunkSize), 256 KB), remaining)`; `chunkSize` (2 MB) and
  `subReadSize` (256 KB) are parameter *defaults*, not formula literals; `T` is the **last**
  sub-read's rate, unsmoothed; cold start is the 256 KB floor.
- `SMBFileShareClient.readRange`: one `pread` when `totalBytes <= maxReadSize` (note `<=`), else
  `PipelinedRangeReader` — a **sliding window** of 4 (`maxPipelineDepth`), refilled per
  completion, reassembled by index. `FileHandleCache` (max 8) reuses open handles.
- Fill task priority is `.utility` (the library's `eventLoopQueue` is `.userInitiated`).
- `maxConcurrentDownloads` default 3, clamped 1–5; pool = `maxConcurrentDownloads + previewReserve
  (5)`; the reserve is further split by `previewFirstPaintReserve = 1`. The rc5 runs' 9–13
  delivery threads come from that reserve.

**tvOS/xctrace gotchas recorded in the verdict:** `devicectl install` over an existing install
preserves the local-network grant (deleting resets it); an unattended run needs
`isIdleTimerDisabled` + a raised *Sleep After*; `--console` is a different launch form than the
one `docs/PROFILING.md` proved, so the no-debugger-library check must run on it; a `.dynamic`
SwiftPM product needs an embed-and-sign step in a hand-written pbxproj or the app dyld-faults on
device with no build error. Nested SwiftPM packages are unreachable from `make test` and CI
(`swift test` at the root only).

See also [[inbound-profiling-review]], [[review-gate-recurring-findings]].

---

**Round 2 — `receive-length-decision-record` (2026-09-05) → APPROVED WITH CONDITIONS.** The user
re-scoped #46 from a device sweep to a docs-and-tooling record (a chunk-ceiling line in
`profile-summary.sh`, a dated decision subsection in `docs/PROFILING.md`, one comment sentence).
Verified: `channelRead` emits one `TransportRead` and forwards that buffer as one `InboundChunk`,
so post-#45 the cap *is* the ceiling of the chunk distribution and the rc5 bundles bound any cap
in [64 KB, 1 MB]. Durable lessons:

- **A metric line whose fixtures all sit far below its thresholds has zero coverage.** The three
  profiling fixtures top out at 1 500 bytes; the five 64 KB–1 MB threshold shares would have been
  `0.000%` everywhere. Check that new tooling metrics have a fixture in their *interesting* range.
- **`InboundChunk` is only a proxy for the receive length while the coalescing ratio is 1.00.**
  Pre-#45 bundles (`--pairing global`) and QUIC captures coalesce or lack `TransportRead`; any
  ceiling/at-cap reading must be qualified by that ratio.
- **A verification task must not name the number it verifies** ("verify it reports 65") — that
  converts an independent recomputation into a confirmation.
- **An exact invariant across runs that differ in everything else is an artefact signature.** The
  identical 65 at-cap chunks in three rc5 runs stays unexplained; the record keeps it as a caveat
  and shows the bound holds under either explanation.
- **A decision *not* to change must say so in the record**, or it reads as a change that skipped
  `docs/PROFILING.md`'s before/after-delta rule.
- **Spec-delta ruling:** a new output line of an existing script is a MODIFIED delta of the
  requirement that enumerates that script's output, not an ADDED requirement. A doc metrics-table
  row that refines an already-enumerated metric ("inbound chunk-size distribution") needs no delta.
- **Revisit thresholds must carry their arithmetic.** 5 % at-cap share is defensible only as a
  shape-change tripwire (an order of magnitude above the 0.25–0.43 % observed), not as a
  break-even point — at 5 % the merge saves ~33 ms against #45's ~0.4 s.
