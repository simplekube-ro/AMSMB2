## Why

PR #43 shipped three op-count wins on the SMB-over-NIO inbound streaming path and deliberately
deferred the structural work (issue #45, the inbound push-conversion that removes the
cooperative-pool thread hop; issue #46, tuning `maximumReceiveLength`) because the only trace
available could not judge them: a Debug build launched from the Xcode debugger with the GCD and
Hangs instruments on, where ~76% of the headline CPU was Instruments overhead. A second capture
taken the same day (`ios-timeprofiler.trace`, Time Profiler only) was also a debugger launch
(`libBacktraceRecording.dylib` is loaded in both bundles) and its bundle no longer opens cleanly
in Xcode 26.6's `xctrace`. There is no Release-build baseline, no repeatable procedure, and
nothing in the library that gives targeted, low-overhead timing of the inbound path — so #45 and
#46 cannot be evaluated with real signal. This change is the measurement gate tracked as
[issue #44](https://github.com/simplekube-ro/AMSMB2/issues/44); target **6.0.0-rc4** (the
consumer app pins 6.0.0-rc3, whose inbound hot path is identical to 6.0.0-rc1).

## What Changes

- **`os_signpost` instrumentation on the inbound hot path** (Apple seam only, always compiled
  in, one boolean check per point when no instrument is recording): one event when the TCP
  transport receives a chunk on the network stack's queue, one event when the bridge appends
  that chunk (the delay between the two is the cooperative-pool pump hop that #45 removes), one
  interval per service dispatch (inbound-ready signal armed → the pass begins on the event-loop
  queue, or the seam is torn down first), one interval per service pass (marked terminal when
  the pass tore the seam down, on either failure path), and one event per libsmb2 `recv` drain (bytes copied, zero for EOF, or would-block).
  All five share one documented subsystem/category so a single instrument filter captures them.
  No public API change; no behaviour change on any path. The only internal signature change is
  that the two debounce-clearing sites report whether a signal was armed, which the pairing test
  observes.
- **A committed capture procedure** in `docs/PROFILING.md`: Release build via the app's Profile
  action, physical device (primary target: Apple TV, the low-power streaming target), Time
  Profiler with the Hangs/GCD instruments removed and the `os_signpost` instrument filtered to
  our subsystem, the RandomPlayer cache-fill workload, the exact `xctrace record` /
  `xctrace export` commands, the metrics to record, and a "Baseline" section that holds the
  captured numbers (date, device, AMSMB2 version, per-thread CPU signature, throughput,
  chunk-size distribution, dispatch latency, stalls).
- **A summary script** `scripts/profile-summary.sh` that turns a `.trace` bundle (or an
  already-exported XML directory) into the before/after numbers (per-thread CPU distribution
  from the time-profile table; counts, byte totals, size and latency percentiles, pump-hop
  latency and throughput from the signpost table, including the read-to-chunk coalescing ratio that shows how far the
  pump falls behind, with terminal passes kept out of the percentiles), so the delta for #45/#46
  is computed the same way every time instead of read off the Instruments GUI. A small hand-written export
  fixture under `test-fixtures/profiling/` pins its parsing and arithmetic in-repo.
- **The baseline capture itself** on the Apple TV, recorded in `docs/PROFILING.md` and summarised
  on issue #44; #45 and #46 are cross-referenced as gated on it.
- Documentation: `README.md` documentation index links the new doc; `docs/ARCHITECTURE.md` file
  map gains the signpost helper file.

## Capabilities

### New Capabilities
- `inbound-profiling`: the signpost emission contract on the seam inbound path (subsystem,
  category, the five instrumentation points and their metadata, the one-check-when-idle and
  Apple-only guarantees, the begin/end pairing invariant), the Release-build on-device capture procedure and its recorded
  baseline, and the trace summary tooling that produces comparable before/after numbers.

### Modified Capabilities
<!-- none: the inbound path's behaviour, the transport-bridge and transport-servicing
     requirements, and the README/architecture doc requirements are unchanged; the new doc and
     the file-map row are additive. -->

## Impact

- **New file** `AMSMB2/Signposts.swift` — internal signpost helper (`#if canImport(Network)`,
  MIT header): the subsystem/category constants, the shared `OSLog`, and one static function per
  instrumentation point, each guarded on `signpostsEnabled`, so the hot-path files do not import
  `os.signpost` themselves and nothing is formatted or allocated when idle.
- `AMSMB2/TCPTransportApple.swift` — `InboundBufferingHandler.channelRead` emits the transport
  read event after the `ByteBuffer → Data` copy. No change to buffering or continuation handling.
- `AMSMB2/TransportBridge.swift` — `appendInbound` emits the chunk event; `cRecv` emits the drain
  event. No change to the FIFO, the copy loop, or the return-value precedence.
- `AMSMB2/Context.swift` — `consumeInboundReadySignal` opens the dispatch interval when it arms
  the signal; a new `clearInboundReadySignal() -> Bool` closes it when it was armed and is used by
  `beginServicePass` (now `@discardableResult -> Bool`) and `teardownSeam`; `serviceContextForSeam`
  is bracketed by the pass interval, whose end carries a terminal marker when the pass tore the
  seam down (read from the bridge slot the teardown clears, on the same queue). No change to the
  debounce logic.
- **New file** `docs/PROFILING.md`; **new file** `scripts/profile-summary.sh`; **new fixture**
  `test-fixtures/profiling/sample-export/`; `README.md` and `docs/ARCHITECTURE.md` gain one line
  each.
- **Tests**: a new unit test pins the subsystem/category the doc's instrument filter names to the
  constants in code (so a rename cannot silently break the procedure); a new pairing test in the
  servicing-loop suite proves every armed signal is cleared exactly once across coalesce, re-arm
  and teardown; the existing `TransportBridgeTests`, `TCPTransportAppleTests` and
  `SMB2ServicingLoopTests` guard that behaviour is unchanged; the summary script is verified
  against the committed fixture (and, operator-locally, against a real bundle). Both new test
  files are guarded so the Linux test target keeps compiling.
- **Not touched**: `SMBTransport`, `QUICTransportApple`, libsmb2, the Linux build (the seam code
  and the helper are Apple-only), the public API and the Objective-C surface.
- **Out of scope** (deliberately): the push-conversion (#45), the receive-length sweep (#46),
  app-side signposts in RandomPlayer, and committing `.trace` bundles (they are large,
  gitignored in the consumer repo, and version-fragile — only the summarised numbers are kept).

## Review

**Verdict:** APPROVED (re-gate 2 — all round-1 conditions and both re-gate-1 items closed)
**Reviewer:** project-architect
**Date:** 2026-09-04 (round 1, re-gate 1, re-gate 2)

### Round 1 (2026-09-04) — APPROVED WITH CONDITIONS

The shape is right and I endorse it. Instrumenting the seam inbound path with `os_signpost`
behind a single internal helper (D2) keeps `Context.swift` and `TransportBridge.swift` free of
log handles and format strings, adds no public API, and touches no lock, no FIFO and no debounce
— so the baseline measures the shipped hot path rather than a variant of it. D1's choice of the
legacy `os_signpost` API over `OSSignposter` to avoid smuggling a platform-floor bump into a
measurement change is correct and I verified the availability arithmetic (O1). D3's "no
overlapping same-name intervals" argument is sound and I traced it against the actual debounce
(O3). The operator gate for the capture matches the `docs/INTEROP-QUIC.md` precedent for work
that cannot be proven in a sandbox.

The conditions below are one substantive measurement gap (the interval named as the dispatch
latency does not span the hop that #45 removes), one performance claim that is false as written
(the vararg allocation defeats "zero cost when idle"), one thread-safety detail, and a set of
verifiability/precision gaps. None of them change the shape of the design.

### Conditions (address before `/opsx:apply` completes; artifacts must reflect them)

1. **`ServiceDispatch` does not measure the hop #45 removes — fix the claim, and either add the
   fifth point or state the gap.** Traced: `InboundBufferingHandler.channelRead`
   (`TCPTransportApple.swift:588`, NIO event loop) copies the `ByteBuffer` into `Data` and
   resumes `receive()`'s continuation → the inbound pump `Task` on the cooperative pool →
   `TransportBridge.appendInbound` → `consumeInboundReadySignal` (`dispatchBegin`). The entire
   NIO-queue → cooperative-pool hop happens *before* `dispatchBegin`. So the design's Non-Goals
   sentence "The pump-hop cost shows up in Time Profiler's per-thread view and in the
   `ServiceDispatch` latency" is false in its second clause, and `ServiceDispatch` measures only
   the cooperative-pool → `eventLoopQueue` hop. Resolve one of two ways, and update Non-Goals
   either way: **(a)** add a fifth event `TransportRead` (byte count) in
   `InboundBufferingHandler.channelRead`, inside the existing `#if canImport(Network)` region, so
   the `TransportRead → InboundChunk` delta *is* the pump hop the push-conversion deletes —
   propagate to the spec's first requirement, `docs/PROFILING.md`'s metrics table, the script and
   tasks 2.x/3.1; or **(b)** delete the false clause and add an explicit "what this does not
   measure" paragraph to design Non-Goals and to `docs/PROFILING.md`, naming the pump hop and
   stating that the only #45 evidence available is the per-thread CPU signature plus end-to-end
   throughput. I recommend (a) — it is one line in a file already inside the seam, and it is the
   difference between judging #45 and guessing at it.

2. **"Zero cost when idle" is false as designed — guard every emit on `signpostsEnabled`.** Swift
   constructs the `[any CVarArg]` vararg array at the *call site*, before entering
   `os_signpost`, whose own enablement check is inside the callee. Every `chunk(bytes:)` and
   `recv(bytes:)` therefore heap-allocates an existential array on each inbound chunk and each
   drain call — with no recorder attached, inside `TransportBridge.lock`. That contradicts the
   spec's "SHALL cost no more than the signpost enablement check". Fix in the helper: each emit
   function starts with `guard InboundSignposts.log.signpostsEnabled else { return }` before the
   `os_signpost` call (`OSLog.signpostsEnabled` carries the same macOS 10.14 / iOS 12 / tvOS 12 /
   watchOS 5 availability as `os_signpost`, verified against the SDK interface). Record it in D1
   and D2 and add it to task 1.2's verification.

3. **Do not store a mutable signpost ID on `SMB2Client`.** D3's "creates one
   `OSSignpostID(log:object:)` from itself at seam connect" implies a `var` written on
   `eventLoopQueue` inside `connectWithBridge` and read by `consumeInboundReadySignal`, which
   runs *off* the queue from the inbound pump — a data race that `@unchecked Sendable` hides from
   the compiler and TSan will find. Make it a `let` initialised in `init`, or derive it on demand
   (`OSSignpostID(log: InboundSignposts.log, object: self)` is deterministic per object, needs no
   storage, and is equally valid in `teardownSeam`). `OSSignpostID` is `Sendable` and `OSLog` is
   `@unchecked Sendable` in the SDK, so a `let` is clean under Swift 6. Update D3 and task 2.2.

4. **Guard the helper on `canImport(Network)`, not `canImport(os)` — and guard the test file.**
   D2 leans on "`canImport(Network)` implies `canImport(os)`". That is true today, but the file's
   own predicate should match its only consumers; under `canImport(os)` alone the file is dead
   code on any Apple configuration without Network, which the dead-code gate forbids. The sharper
   problem is the test: `AMSMB2Tests/SignpostContractTests.swift` references `InboundSignposts`
   and will break the **Linux test target**, which `make linuxtest` compiles — task 2.3 only
   promises "the Linux target still builds". Add the same guard to the test file (D5, task 1.1)
   and make task 2.3's Linux check `swift test`, not `swift build`.

5. **Give the two interval scenarios a verification path that is not a manual trace read.**
   "Dispatch and pass intervals bracket the hop" and "Teardown closes a pending dispatch
   interval" are today assertable only from a live recording, and task 5.2 checks nothing beyond
   "all four names appear with non-zero counts". The begin/end *pairing* invariant is unit-testable
   at seams `SMB2ServicingLoopTests` already drives synchronously
   (`consumeInboundReadySignal` / `beginServicePass` / `teardownSeam`): have `beginServicePass()`
   and `teardownSeam()`'s debounce reset report whether the flag was armed, then add a red test
   asserting that every `consumeInboundReadySignal() == true` is followed by exactly one armed
   clear across the coalesce, re-arm and teardown cases. D4 already requires reading the prior
   value under the lock to guard `dispatchEnd`, so this exposes something the implementation needs
   anyway — and it supplies the **red step that tasks 2.1/2.2 currently lack** (both are
   green-only, with existing tests used purely as regression guards; TDD needs one failing test
   that encodes why the pairing matters).

6. **Correct the two scenarios that assert more than the design delivers.**
   (a) *"ending at the instant the `ServicePass` interval for the same client begins"* — false
   when `serviceContextForSeam`'s `guard let context else { return }` fires (context already
   destroyed): `beginServicePass` emits `dispatchEnd`, `passBegin` never runs. Reword to: the
   interval ends when the pass begins on the event-loop queue; if the context has already been
   destroyed the dispatch interval still closes and no pass interval is emitted.
   (b) *"with the copied bytes summing to 262144"* — `cRecv` gathers across the FIFO up to
   `maxLen` and is not aligned to chunk boundaries, so no bounded set of `RecvDrain` events sums
   to one `InboundChunk`. Restate as a per-event contract (each `RecvDrain` reports the bytes that
   call copied; zero means EOF; would-block is distinguishable) plus an aggregate the script can
   actually check (total `RecvDrain` bytes ≈ total `InboundChunk` bytes over the capture).

7. **`ServicePass` includes the terminal teardown — say so, and keep it out of the percentiles.**
   `serviceContextForSeam`'s error path calls `teardownSeam()` and
   `failPendingAndDestroyContext(...)` before the `defer`-ed `passEnd`, producing exactly one pass
   whose duration is dominated by context destruction. The spec is right to include it; D6 and D7
   must state that the summary script reports the terminal pass separately, or computes
   median/p95 over non-terminal passes — otherwise a single outlier moves the number the #45/#46
   decision rests on.

8. **The script's fixtures live outside the repo — say so, and add one that does not.** Tasks
   3.2/3.3 smoke-test against `../RandomPlayer/ios.trace` and `../RandomPlayer/ios-timeprofiler.trace`.
   Both exist on this machine; neither is in this repository and per the proposal both are
   gitignored in the consumer repo — so the "Summary from an existing bundle" and "Summary from a
   baseline bundle" scenarios are not reproducible by another contributor or by CI. Either commit
   a small synthetic `xctrace export` XML under the existing `test-fixtures/` directory and give
   the script a documented "parse this XML instead of exporting" entry point (making the
   back-reference resolution testable anywhere), or state plainly in D6 and in the spec that those
   two scenarios are operator-local and only "Unreadable bundle" is repo-reproducible.

9. **D8's CHANGELOG does not exist.** There is no `CHANGELOG.md` in this repository; release
   notes live on the GitHub release and the issue. Either drop the sentence or add an explicit
   task naming the artifact that actually carries "the library now emits signposts under
   `ro.SimpleKube.AMSMB2`" — it is the only consumer-visible signal this change produces.

10. **Soften D4's lock-safety wording to the property that is load-bearing.** "It does not take
    locks, block, or call out" is stronger than Apple documents (`os_signpost` writes into the
    firehose buffer and may take an internal lock or allocate on first use). The argument that
    actually holds, and the one to put in the risk row and the helper's doc comment, is:
    *`os_signpost` never calls back into AMSMB2 code, so it cannot re-enter `serviceFlagLock` or
    `TransportBridge.lock`; no lock-ordering or reentrancy hazard exists, and the only cost inside
    the critical section is a bounded, non-blocking buffer write.* With condition 2 applied, the
    idle case reduces to a boolean check.

11. **New file conventions.** `AMSMB2/Signposts.swift` needs the MIT file header per Code Style —
    add it to task 1.2's verification. Task 4.2 already covers the `docs/ARCHITECTURE.md` file-map
    row; make sure that row names the layer the helper belongs to, consistent with the existing
    seam rows.

### Observations (no action required)

- **O1 — D1's availability claim verified against the SDK.** `os_signpost`, `OSSignpostType`,
  `OSSignpostID` and `OSLog.signpostsEnabled` are all annotated
  `@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)`, strictly below every
  `Package.swift` floor (macOS 10.15, iOS 13, macCatalyst 13, tvOS 14, watchOS 6, visionOS 1). No
  `if #available` branch is needed anywhere. Rejecting `OSSignposter` (iOS 15 / macOS 12 /
  tvOS 15) rather than bumping the floor inside a measurement change is the right call.
- **O2 — Swift 6 strict concurrency is clean.** The SDK declares
  `extension OSLog : @unchecked Sendable` and `public struct OSSignpostID : Sendable`, so a
  `static let` `OSLog` on a caseless enum compiles under the package's Swift 6 language mode
  (tools 6.0, `ExistentialAny` enabled). No `nonisolated(unsafe)` needed.
- **O3 — D3's no-overlap argument holds, verified against the code.** `servicePending`
  transitions `false → true` only in `consumeInboundReadySignal` and `true → false` only in
  `beginServicePass` and `teardownSeam`, all three under `serviceFlagLock`, so exactly one clear
  site observes the armed flag and begins/ends pair 1:1 with no overlap on either name.
  `ServicePass` is non-reentrant: `serviceContextForSeam` has exactly one call site
  (`Context.swift:1672`, inside `eventLoopQueue.async`), and neither `flushOutboundForSeam`'s
  32-pass re-arm nor `scheduleSeamTimeout`'s work item routes back through it — they call
  `smb2_service` / `smb2_service_timeout` directly.
- **O4 — D4's placements are reachable and correctly located.** `appendInbound`'s
  `if !data.isEmpty` (`TransportBridge.swift:474`) is the only enqueue site, and the handler is
  captured after it and invoked outside the lock, so the chunk event lands before the signal and
  the trace shows the right causal order. In `cRecv` the return precedence
  (`isClosed → bytes → EOF → error → EAGAIN`) is untouched by inserting emits before three of the
  five returns, and `copied` is provably ≥ 1 in the bytes branch (`inboundCount > 0` and the FIFO
  never holds empty chunks), so `RecvDrain(0)` unambiguously means EOF.
- **O5 — teardown during a pass emits a semantically premature `dispatchEnd`.** If a chunk arms a
  fresh signal while `serviceContextForSeam` is running and that pass then errors into
  `teardownSeam`, the newly armed dispatch interval is closed by teardown and its pass never
  happens. Correct for interval hygiene (nothing dangles), but the trace will show a short
  dispatch interval with no following pass — worth one line in the metrics section of
  `docs/PROFILING.md` so a reader does not misread it as a lost wakeup.
- **O6 — no MODIFIED spec deltas are needed; "none" is right.** `readme-revision`'s
  "Documentation links section" and `architecture-docs`'s "File structure map" are both
  non-exhaustive ("with links to `docs/ARCHITECTURE.md` and `docs/API.md`", "including the
  transport seam files"), and `docs/INTEROP-QUIC.md` was previously added to the README index
  without a delta. Consistent with precedent.
- **O7 — the unit suite will leave unpaired intervals.**
  `testTeardownSeamResetsInboundReadyDebounce` ends with an armed signal that is never cleared, so
  a recorder attached to the *test* bundle would see a dangling `ServiceDispatch`. Harmless during
  `swift test`; no action.
- **O8 — the dead-code gate is satisfiable as specified.** Seven helper functions (eight with
  condition 1(a)), each with exactly one non-test call site, so task 2.3's
  `grep -n "InboundSignposts\." AMSMB2/*.swift` is the right check. `recvWouldBlock()` is the
  narrowest case, but `TransportBridgeTests` already drives the `EAGAIN` return, so its call site
  is exercised.
- **O9 — the operator gate is the right shape.** Naming `libBacktraceRecording.dylib` /
  `libLogRedirect.dylib` as the disqualifying fingerprint is the single most valuable line in the
  procedure: it is the concrete, checkable reason both existing traces are worthless, and it makes
  the capture self-validating exactly as D7 claims.
- **O10 — the rc4 faithfulness argument is sound but unreproducible as written.** Name the
  `git diff` it rests on (the rc1→rc3 range over `AMSMB2/TransportBridge.swift`,
  `AMSMB2/TCPTransportApple.swift`, and the `#if canImport(Network)` region of
  `AMSMB2/Context.swift`) so a later reader can re-run it instead of trusting the sentence.

### Conditions addressed (2026-09-04, after review)

All eleven conditions are reflected in the artifacts; none changed the shape of the design.

1. **(a) taken.** A fifth event `TransportRead` is emitted in `InboundBufferingHandler.channelRead`
   after the `Data` copy; the `TransportRead → InboundChunk` delta is the pump hop #45 deletes.
   Spec requirement 1, design Context/Goals/Non-Goals/D2/D4/D6, the doc metrics (D7), the script
   pairing logic, and tasks 2.3/3.x/5.2 all carry it. The false Non-Goals clause is gone.
2. Every emit function starts with `guard log.signpostsEnabled else { return }` (D1, D2, task
   1.2's grep check); the spec now says "one signpost-enablement check (no allocation, no
   argument formatting)".
3. No stored ID: the interval functions take `for object: AnyObject` and derive
   `OSSignpostID(log:object:)` at the call (D3, task 2.2).
4. Helper and `SignpostContractTests.swift` are both under `#if canImport(Network)`; task 2.4's
   Linux check is `make linuxtest` (`swift test`), and the spec's platform sentence covers the
   test target.
5. `beginServicePass()` is `@discardableResult -> Bool` via a shared
   `clearInboundReadySignal() -> Bool` also used by `teardownSeam`; task 2.1 is the red pairing
   test (coalesce / re-arm / teardown), spec scenario "Begin and end are paired one-to-one"
   names it (D5).
6. Both scenarios reworded: the dispatch interval "ends when the pass begins … if the context was
   already destroyed the dispatch interval still ends and no pass interval is emitted"; the
   drain contract is per-event with the aggregate "total `RecvDrain` bytes equal total
   `InboundChunk` bytes minus whatever remained buffered".
7. *(Superseded by Re-gate 1, R1 — the explicit-end approach missed the flush-path teardown.)*
   Now: `passEnd(for:terminal:)` from a `defer`, terminal on both teardown paths, terminal passes
   reported separately and excluded from percentiles by the script (spec bullet, D4, D6).
8. Committed fixture `test-fixtures/profiling/sample-export/` (hand-written export XML with
   back-references plus `expected.txt`); the script accepts an export directory; the spec's
   script scenarios run on the fixture; the consumer-repo bundle is an explicitly optional
   operator-local check (D6, tasks 3.1–3.4).
9. CHANGELOG reference removed; the rc4 GitHub release notes carry the consumer-visible note
   (D8, task 5.1).
10. D4 and the risk row now state the load-bearing property only: `os_signpost` never calls back
    into AMSMB2, so no reentrancy or lock-ordering hazard; a bounded non-blocking write while
    recording, one boolean when idle.
11. MIT header in task 1.2; the ARCHITECTURE file-map row names its layer (Transport (Apple)) in
    task 4.2.

Observations acted on: O5 (teardown-closed dispatch interval note in the doc metrics, D7 and
task 4.1) and O10 (the rc1→rc3 `git diff` commands are named in design Context).

### Re-gate 1 (2026-09-04)

**Verdict at the time: revision required (now closed — see Re-gate 2).** Narrowly. Conditions 1–6 and 8–11 are verified closed against the
code and the artifacts; O5 and O10 are closed. Conditions 7 and 10's neighbourhood are where the
two open items sit, and both are the same class of problem: a spec sentence that promises more
than the placement delivers, and a script algorithm that is wrong in exactly the regime the
change exists to measure. Both are artifact-level edits; nothing about the shape of the design
changes, and no other rework is required. Fix R1 and R2, then this is an APPROVE.

#### R1 — `flushOutboundForSeam`'s error path still puts teardown inside a `ServicePass`

Excluding teardown at the source (condition 7's chosen resolution) is the **right instinct** and I
endorse it over my original "include it and report separately": the pass interval then measures
what its name claims, and the script needs no outlier handling. But the D4 placement is
incomplete, and dropping `defer` is what makes the gap silent.

`serviceContextForSeam` has *two* teardown paths, not one:

1. `smb2_service(revents) < 0` → the branch D4 covers. `passEnd` before `teardownSeam()`. Correct.
2. `flushOutboundForSeam(context:)` — called from inside `serviceContextForSeam` — has its own
   `smb2_service(POLLOUT) < 0` branch (`Context.swift:1851–1855`) that calls `teardownSeam()` and
   `failPendingAndDestroyContext(...)` itself and then `return`s. Control comes back into
   `serviceContextForSeam`, which falls through to `scheduleSeamTimeout()` (a no-op once
   `transportBridge` is nil) and *then* emits `passEnd`. On that path the interval contains the
   full teardown and context destruction — precisely the outlier condition 7 removed, and the
   spec's absolute "teardown cost never lands in a pass duration" is false.

Pick one and reflect it in D4 and in the `ServicePass` bullet of the spec:

- **(a) Scope the guarantee.** Keep the placement, and change the spec to "the interval ends
  before teardown on the direct service-failure path", with D4 stating explicitly that a failure
  inside `flushOutboundForSeam` tears down within the pass and yields one terminal outlier, and
  `docs/PROFILING.md` naming it in the metrics section (one line, alongside the O5 note). Cheapest,
  fully honest, no code shape change.
- **(b) Make it uniform.** Restore the `defer`-based `passEnd` and give it a terminal flag —
  `passEnd(for:terminal:)` emitting `%d` 0/1 — so the script filters terminal passes out of the
  percentiles. This covers *every* teardown path uniformly, including any added later, and removes
  the ordering puzzle entirely. Costs one extra metadata field and one script filter.

Do **not** refactor `flushOutboundForSeam` to report its failure upward so the caller can order the
`passEnd` — that rewrites working error-handling in a measurement change (CLAUDE.md rule 3) and it
is also called from `scheduleSeamTimeout`'s work item and from `connectWithBridge`, where no pass
interval is open.

#### R2 — the pump-hop pairing heuristic is unsound, and fails hardest where it matters

D6 pairs "each `InboundChunk` with the nearest preceding unpaired `TransportRead` of the same byte
count", and the risk row argues that a strictly sequential pump makes the pairing exact. The
sequential pump is what *breaks* it. In `InboundBufferingHandler` (`TCPTransportApple.swift`):

- `channelRead` resumes a waiting `receive()` continuation only if one is suspended; otherwise it
  does `buffer.append(received)`.
- `receive()`'s fast path returns **the whole accumulated `buffer`** as one `Data` and clears it.

So whenever the pump is not already parked in `receive()` — which is exactly when the cooperative
pool is backed up, i.e. the condition #45 is about — N `channelRead`s of sizes a, b, c accumulate
and the next `receive()` yields a single `Data` of size a+b+c. The trace then holds three
`TransportRead` events and one `InboundChunk` of a different size than any of them: the byte-count
heuristic matches nothing, silently drops the sample, and the surviving pairs are biased toward the
uncontended 1:1 case. The reported pump-hop latency would look *best* precisely when the hop is
worst.

Required changes:

1. **Pair by sequence and byte conservation, not by equality.** Keep a FIFO of `TransportRead`
   events; for an `InboundChunk` of size S, pop `TransportRead`s until their sizes sum to S. Report
   the hop as `InboundChunk.timestamp − firstPopped.timestamp` (the queueing delay of the oldest
   coalesced byte — the number #45 improves) and, if useful, `− lastPopped.timestamp` as the
   floor. FIFO order and total-byte conservation make this exact for the TCP transport, and it
   degrades to the 1:1 case automatically. Update D6, the "Trace summary tooling" requirement's
   pairing sentence, and the fixture (task 3.1) so it contains at least one coalesced group.
2. **Report the coalescing ratio as a first-class metric**: `TransportRead` count divided by
   `InboundChunk` count, and the distribution of `TransportRead`s-per-`InboundChunk`. A ratio above
   1 *is* the evidence that the pump hop is a bottleneck, and it is robust to any pairing subtlety.
   Add it to D6, the tooling requirement, `docs/PROFILING.md`'s metrics table, and task 5.2.
3. **Rewrite the risk row.** Coalescing is the expected steady-state behaviour of
   `InboundBufferingHandler`, not a rare mis-pairing edge case. The current row asserts the
   opposite.

#### Answers to the three questions asked

- **(7) Excluding teardown at the source: agreed, with R1.** Simpler and more honest than reporting
  an outlier — provided the exclusion actually holds on both teardown paths, or the guarantee is
  scoped to the one it holds on.
- **(D6) The pairing heuristic: not sound.** See R2. The premise "the pump is strictly sequential,
  therefore the orders match" is true for *ordering* and false for *cardinality*; the pairing needs
  the cardinality assumption, which `receive()`'s buffer-drain semantics break.
- **(spec) Implementation leakage: acceptable, no change required.** "on the network stack's own
  queue", "ends when the armed signal is cleared", and "the interval ends before the seam teardown"
  are all trace-observable properties, so they are contract, not internals. The one borderline
  phrase is "a clear with no armed signal reports that nothing was armed" in the pairing scenario,
  which describes an internal return value — but it is what makes the scenario testable without a
  recorder (condition 5), the requirement states the invariant it serves ("no dispatch interval can
  be begun twice or ended twice"), and this repo already specs internal seams elsewhere
  (`quic-transport-apple`). Keep it.

#### Conditions verified closed

1 ✅ `TransportRead` added in `InboundBufferingHandler.channelRead` (file is wholly inside
`#if canImport(Network)`, lines 25–686, so the call site is Linux-safe); the false Non-Goals clause
is gone and the two hops are named separately in Goals, the spec, the doc metrics and task 5.2.
2 ✅ `guard log.signpostsEnabled` in every emit, with the vararg-allocation rationale recorded in
D1 and a grep check in task 1.2; the spec now says "one signpost-enablement check (no allocation,
no argument formatting)". 3 ✅ ID derived on demand from `for object: AnyObject`; D3 records the
rejected `var`-at-connect race explicitly. 4 ✅ helper and `SignpostContractTests.swift` both under
`#if canImport(Network)`; task 2.4 is `make linuxtest`; the spec's platform sentence covers the
test target. 5 ✅ `clearInboundReadySignal() -> Bool` shared by `beginServicePass`
(`@discardableResult -> Bool`) and `teardownSeam`; task 2.1 is a genuine red (the assertions do not
compile against today's `Void` return) and its three sequences are correct against the intended
implementation; the pairing scenario is in the spec and the signature change is disclosed in
Non-Goals and Impact. 6 ✅ both scenarios reworded correctly. 8 ✅ committed fixture plus an
export-dir mode; the spec's script scenarios now run on the fixture and the consumer-repo bundle is
demoted to optional task 3.4. 9 ✅ CHANGELOG reference gone; rc4 release notes carry the note
(D8, task 5.1). 10 ✅ D4 and the risk row state only the no-callback property and explicitly
disclaim the lock-free/allocation-free assumption. 11 ✅ MIT header (task 1.2) and the
`Transport (Apple)` layer in the file-map row (task 4.2). O5 ✅ and O10 ✅ both folded in.

#### Additional observations (fold in with R1/R2; not blocking on their own)

- **O11 — "zero exactly once, for EOF" overclaims.** Nothing guarantees libsmb2 calls `cRecv`
  exactly once after `inboundEOF` is set; the code guarantees only that a zero return *means* EOF
  (`copied ≥ 1` in the bytes branch). Reword the drain scenario to "zero only for EOF".
- **O12 — a QUIC seam emits no `TransportRead`.** D2/D4 scope it to `TCPTransportApple`
  deliberately, which is right for a TCP baseline, but a capture taken over QUIC will show an empty
  pump-hop section. One line in `docs/PROFILING.md`'s metrics table ("TCP transport only") prevents
  a future reader reading that as a regression.
- **O13 — the aggregate byte check in the drain scenario is soft.** "total `RecvDrain` bytes equal
  total `InboundChunk` bytes minus whatever remained buffered" is not checkable from the trace
  alone, since the remainder is not emitted. It is fine as the operator-gate approximation task 5.2
  words it ("within the final buffered remainder"); consider saying so in the scenario too.

### Re-gate 1 conditions addressed (2026-09-04)

- **R1** — `passEnd(for:terminal:)` is emitted from a `defer` with
  `terminal: transportBridge == nil`, which is true after either teardown path (direct service
  failure, or the flush failure inside `flushOutboundForSeam` that returns normally). The spec's
  `ServicePass` bullet and the new "Terminal pass is marked" scenario say the interval includes
  teardown and carries the marker; D4 explains the two paths and why the read is race-free; D6
  and task 3.2 keep terminal passes out of the percentiles and list them separately; the fixture
  (task 3.1) contains one.
- **R2** — Pairing is now FIFO byte-sum: `TransportRead`s are consumed in order until they sum
  to each `InboundChunk`, latency is measured from the first consumed read, an overshoot is a
  reported pairing error, and the `TransportRead`/`InboundChunk` coalescing ratio is a
  first-class metric in the spec, D6, the doc metrics (D7, task 4.1), task 3.2, task 5.2 and the
  fixture (a coalesced group). D4's `channelRead` bullet and the rewritten risk row state that
  the sequential pump is what causes coalescing and why FIFO byte-sum pairing is exact for TCP.
- Notes: "zero exactly once" is now "a zero means EOF"; `TransportRead` is marked TCP-only in the
  spec and the doc metrics; the aggregate check is now trace-checkable (`InboundChunk` bytes
  equal `TransportRead` bytes; `RecvDrain` bytes never exceed `InboundChunk` bytes, the script
  reports the buffered remainder).

### Re-gate 2 (2026-09-04)

**Verdict: APPROVED.** R1 and R2 are closed, and closed correctly — I re-derived both against the
code rather than taking the summary on trust. Nothing further is required before `/opsx:apply`.
The three observations below are refinements to fold in while implementing; none of them changes
an artifact's shape and none blocks.

**R1 verified.** `defer { passEnd(for: self, terminal: transportBridge == nil) }` is the right
marker and the race-freedom argument holds: `transportBridge` has exactly two write sites,
`Context.swift:1675` (inside `connectWithBridge`'s `eventLoopQueue.async` install block) and
`Context.swift:1917` (`teardownSeam`, which runs on `eventLoopQueue` — `deinit` reaches it through
`shutdown()` either already on the queue or via `eventLoopQueue.sync`, lines 234/236). The `defer`
reads it on the same serial queue the pass runs on, so no barrier is needed. It is also correct on
both failure paths, which is what option (b) bought: the direct `smb2_service < 0` branch and
`flushOutboundForSeam`'s `smb2_service(POLLOUT) < 0` branch (`Context.swift:1851–1855`, which tears
down inside the callee and returns normally into `scheduleSeamTimeout()`) both leave
`transportBridge` nil. D4's "at most one terminal pass per connection" also checks out:
`failPendingAndDestroyContext` nils the context, so every later pass exits at the `guard let
context` before `passBegin`.

**R2 verified, and the exactness claim is stronger than stated.** `InboundBufferingHandler` holds
the invariant that a non-empty `buffer` and a parked `waitingContinuation` are mutually exclusive
(`receive()` parks only when the buffer is empty; `channelRead` resumes a parked continuation
without touching the buffer). So every `Data` handed to the pump — whether the direct-delivery case
or the buffer-drain case — is a *contiguous prefix* of the `TransportRead` FIFO. FIFO byte-sum
pairing is therefore exact by construction, not merely by the sequential-pump argument D6 gives,
and the overshoot check is a genuine guard for a future transport rather than a fudge. Measuring
from the first consumed read is the right choice: it is the queueing delay of the oldest coalesced
byte, which is what #45 improves. Promoting the coalescing ratio to a first-class metric is the
best addition in this round — it is the one number that survives any pairing subtlety and it reads
directly as "how far behind the pump is".

**Notes closed.** "a zero means EOF" is now accurate against `cRecv` (`copied ≥ 1` in the bytes
branch). `TransportRead` is marked TCP-only in the spec bullet, the doc metrics and D7/task 4.1.
The aggregate check is now genuinely trace-checkable: `InboundChunk` bytes == `TransportRead` bytes
(coalescing changes counts, never bytes) is exactly right, and `RecvDrain ≤ InboundChunk` with the
remainder reported is the honest form of what I flagged as unverifiable.

#### Observations to fold in during `/opsx:apply` (non-blocking)

- **O14 — the terminal marker's true meaning is "the seam was gone when this pass ended".** That
  is what the `defer` reads, and it is the property the script wants. It has no false negatives,
  but one narrow false positive: a service pass already dispatched to `eventLoopQueue` when
  `teardownSeam()` runs (context still alive, bridge nil) would begin, do nothing, and be marked
  terminal. Harmless — a degenerate pass belongs outside the percentiles anyway — but the spec
  scenario's absolute "every other pass in the recording does not [carry the marker]" would be
  violated by it. Reword the scenario to the marker's actual semantics (a pass is terminal exactly
  when the seam is no longer installed at its end), which is both accurate and simpler to check.
- **O15 — guard the pump-hop section against zero `TransportRead` events.** `TransportRead` is
  TCP-only by design, so a QUIC capture (or any bundle from a build before rc4) has none. As
  specified, the FIFO would underflow on every `InboundChunk` and the script would print a pairing
  error per chunk. Have it skip the pump-hop and coalescing sections with a single
  `pump hop: n/a (no TransportRead events)` line when the count is zero, and say so in D6 and the
  tooling requirement's failure wording.
- **O16 — let the pairing FIFO tolerate a zero-byte `TransportRead`.** NIO does not normally
  deliver an empty `ByteBuffer`, but `channelRead` would emit `transportRead(bytes: 0)` if it did.
  Zero-byte entries do not move the running sum, so the pop loop should skip them explicitly rather
  than rely on the sum ever advancing. One line in the script; no artifact change needed beyond a
  parenthetical in D6.

### Re-gate 2 observations folded in (2026-09-04)

- **O14** — the "Terminal pass is marked" scenario now states the marker's real semantics (the
  seam was gone when the pass ended; a pass already dispatched when teardown ran is also marked),
  and D4 records the one narrow false positive.
- **O15** — the tooling requirement, D6 and tasks 3.2/3.3 make the coalescing ratio and pump-hop
  latency print `n/a` when a capture has no `TransportRead` events, with a fixture-based check.
- **O16** — D6 and task 3.2 have the pairing FIFO skip zero-byte reads explicitly.
