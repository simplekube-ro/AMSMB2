## Context

See proposal.md — Why. Current state that shapes the approach:

- The inbound path is a pull loop across three executors per burst: NWConnection's queue
  (`InboundBufferingHandler.channelRead` in `TCPTransportApple.swift` copies the `ByteBuffer`
  into `Data` and resumes `receive()`'s continuation) → the bridge's `inboundPump()` `Task` on
  the Swift cooperative pool (`await transport.receive()` then `appendInbound`) → the
  `_onInboundReady` handler, which runs the lost-wakeup-free debounce
  (`consumeInboundReadySignal` under `serviceFlagLock`, reset by `beginServicePass` *before*
  the drain) and hops to `eventLoopQueue` for `serviceContextForSeam()` → `smb2_service` →
  `cRecv` drains the `[Data]` FIFO. `teardownSeam()` resets the debounce flag. The hop that
  issue #45 removes is the first one (network queue → cooperative pool); the debounce hop is the
  second.
- All of that is under `#if canImport(Network)`; the Linux build never compiles it, and the
  Linux test target (`make linuxtest`) compiles every file in `AMSMB2Tests/`.
- Package floors are iOS 13 / macOS 10.15 / tvOS 14 / watchOS 6. `OSSignposter` needs iOS 15 /
  macOS 12 / tvOS 15; `os_signpost`, `OSSignpostID`, and `OSLog.signpostsEnabled` are available
  from iOS 12 / macOS 10.14 / tvOS 12 / watchOS 5, i.e. at every floor with no availability
  branch (verified against the SDK by the architect review, O1).
- `xctrace` 16 (Xcode 26.6) exports any table of a bundle as XML via `--xpath`; the two Debug
  bundles in the consumer repo are gitignored there (`*.trace/`) and are not available to other
  contributors.
- The consumer's shared scheme already builds Release for the Profile action. The Apple TV
  "Birou" (tvOS 26.6) is the chosen primary target; it is driven by the Siri Remote, so the
  workload steps are operator-performed, not scripted.
- The inbound hot path is unchanged between the tags 6.0.0-rc1 and 6.0.0-rc3, which is what
  makes an rc4 baseline faithful to what PR #43 shipped. Reproduce with:
  `git diff --stat 6.0.0-rc1..6.0.0-rc3 -- AMSMB2/TransportBridge.swift AMSMB2/TCPTransportApple.swift AMSMB2/SMBTransport.swift`
  (empty) and `git diff 6.0.0-rc1..6.0.0-rc3 -- AMSMB2/Context.swift` (touches only
  disconnect/teardown code — the hunks inside the `#if canImport(Network)` region are the
  failure-path `failPendingAndDestroyContext` consolidation and a weak callback capture, not the
  inbound drain, debounce or dispatch).

## Goals / Non-Goals

**Goals:**

- Five instrumentation points, one subsystem, zero behaviour change, a single boolean check
  when idle, no new import in the hot-path files.
- The two hops are measured separately: `TransportRead → InboundChunk` is the pump hop #45
  deletes; `ServiceDispatch` is the debounce + queue hop that stays.
- A procedure an operator can follow without prior Instruments knowledge, whose result is
  self-validating (the doc says how to prove the capture was Release and Time-Profiler-only).
- Numbers produced by a script, so "before" and "after" are computed identically, and the
  script's parsing is reproducible from a committed fixture.

**Non-Goals:**

- Instrumenting the outbound path, NIO internals below `channelRead`, or the QUIC transport's
  receive path (the baseline is TCP; QUIC gets the same `TransportRead` event when it is
  profiled, as a separate change).
- A public API to toggle or observe the signposts. They are internal observability.
- Committing trace bundles, custom `.tracetemplate` files (binary, Xcode-version-bound), or an
  automated on-device workload driver.
- Any change to the debounce, the FIFO, or the copy semantics — those stay exactly as PR #43
  left them, otherwise the baseline would not measure the shipped code. The only signature
  change is that the two debounce-clearing sites report whether a signal was armed (D5), which
  the instrumentation needs and the tests observe.

## Decisions

### D1: `os_signpost` + `OSLog`, guarded by `signpostsEnabled`, not `OSSignposter`

Use `os_signpost(.event/.begin/.end, log:name:signpostID:_:_:)` with a shared
`OSLog(subsystem: "ro.SimpleKube.AMSMB2", category: "Inbound")`. It is available at every
package floor, so no `if #available` branch sits in the hot path and the same code runs on the
tvOS 14 floor and on tvOS 26. Metadata is passed as integer arguments only, formatted
`bytes=%ld` on the three byte events and `terminal=%ld` on the pass end (`%ld`, not `%d`: `Int`
is 64-bit and `%d` truncates; the prefix is what the Instruments narrative shows).

Every emit function starts with `guard log.signpostsEnabled else { return }`. Swift builds the
`[any CVarArg]` vararg array at the call site, before `os_signpost`'s own enablement check, so
without the guard each chunk and each drain would heap-allocate inside `TransportBridge.lock`
with no recorder attached. With the guard, the idle cost is one boolean read.

Alternatives: `OSSignposter` (cleaner API, needs an availability branch or a floor bump — a
floor bump is a semver decision this change should not smuggle in); `kdebug`/`os_log`
(coarser, no interval semantics in the Instruments UI); a compile-time flag (rejected by the
maintainer: the shipped rc binary must carry the signposts so the app pin, not a special build,
is what gets measured).

### D2: One helper file under `#if canImport(Network)`, static functions per point

`AMSMB2/Signposts.swift` (MIT header; `#if canImport(Network)` — the same predicate as its only
consumers, so it is never dead code on any configuration) holds an internal caseless
`enum InboundSignposts` with `static let subsystem`, `static let category`, the `OSLog`, and one
static function per point:

| Function | Point | Kind |
|---|---|---|
| `transportRead(bytes:)` | `TransportRead` | event |
| `chunk(bytes:)` | `InboundChunk` | event |
| `recv(bytes:)` | `RecvDrain` (bytes copied; 0 = EOF) | event |
| `recvWouldBlock()` | `RecvDrain` (would-block marker, `bytes=-1`) | event |
| `dispatchBegin(for:)` / `dispatchEnd(for:)` | `ServiceDispatch` | interval |
| `passBegin(for:)` / `passEnd(for:terminal:)` | `ServicePass` (`terminal=%ld` on end) | interval |

The five signpost names are `StaticString` constants on the enum, so the identifier test (D5) can
pin them to the doc and the summary script the same way it pins the subsystem and category.

`TCPTransportApple.swift`, `TransportBridge.swift` and `Context.swift` call these one-liners and
do not import `os.signpost`. The helper's doc comment carries the reentrancy property from D4.
`AMSMB2Tests/SignpostContractTests.swift` is guarded by the same `#if canImport(Network)` so the
Linux test target keeps compiling.

Rationale: keeps the hot-path files free of format strings and log handles (rule: surgical
changes), gives the identifier test one place to read, and satisfies the dead-code gate (each
function has exactly one call site outside its file).

Alternative: inline `os_signpost` calls in each file — three imports, three copies of the
subsystem string, and format strings scattered through lock sections.

### D3: Signpost IDs — derived on demand from the client, shared by the two interval names

The interval functions take `for object: AnyObject` and compute
`OSSignpostID(log: InboundSignposts.log, object: object)` at the call. `SMB2Client` passes
`self`. The ID is a deterministic function of the object address, so no state is stored on the
client, nothing is written on one queue and read on another, and the same ID is valid from
`consumeInboundReadySignal` (off-queue, from the pump), `beginServicePass` /
`serviceContextForSeam` (on `eventLoopQueue`) and `teardownSeam`.

Names differ, so the two interval kinds never collide; within a kind, at most one interval is
open per client at a time: `ServiceDispatch` because `servicePending` flips `false → true` only
in `consumeInboundReadySignal` and `true → false` only in `beginServicePass` and `teardownSeam`,
all under `serviceFlagLock` (verified by the architect review, O3); `ServicePass` because
`serviceContextForSeam` has one call site inside `eventLoopQueue.async` and nothing re-enters
it. Events use `.exclusive`.

Alternatives: a `var` on the client set at seam connect — a data race hidden by
`@unchecked Sendable` (written on `eventLoopQueue`, read from the pump). A `let` in `init`
would also be race-free but stores what a pure function already gives.

### D4: Exact placement, and what "no behaviour change" means

- `InboundBufferingHandler.channelRead` (`TCPTransportApple.swift`): emit `transportRead(bytes:)`
  right after the `Data` copy, before the lock. This runs on the network stack's queue. Note the
  handler's `receive()` fast path returns the *whole* accumulated `buffer` as one `Data`, so when
  the pump `Task` is behind, N reads of a, b, c bytes become one `InboundChunk` of a+b+c. That
  coalescing is the pump hop made visible: its ratio is a first-class metric, and latency is
  measured from the first coalesced read (D6).
- `TransportBridge.appendInbound`: emit `chunk(bytes:)` inside the existing `if !data.isEmpty`
  block, under the lock, before the handler is captured. (An empty chunk is not enqueued today
  and is not counted.)
- `TransportBridge.cRecv`: emit `recv(bytes: copied)` immediately before `return Int32(copied)`
  (`copied ≥ 1` there, so zero is unambiguous); emit `recv(bytes: 0)` before the EOF `return 0`;
  emit `recvWouldBlock()` before the `EAGAIN` return. Closed/error returns are not instrumented
  (they are terminal, not hot).
- `SMB2Client.consumeInboundReadySignal`: when the flag flips `false → true`, emit
  `dispatchBegin(for: self)` before returning `true` (still under `serviceFlagLock`).
- `SMB2Client.beginServicePass` and `SMB2Client.teardownSeam` both clear the flag through one
  helper, `clearInboundReadySignal() -> Bool`, which returns whether the flag was armed and
  emits `dispatchEnd(for: self)` only in that case, inside the same `withLock`. `beginServicePass`
  becomes `@discardableResult ... -> Bool` and returns that value (D5).
- `SMB2Client.serviceContextForSeam`: `passBegin(for: self)` after the `guard let context`;
  `passEnd(for: self, terminal: transportBridge == nil)` in a `defer`. There are two teardown
  paths inside a pass — the direct `smb2_service < 0` branch, and `flushOutboundForSeam`'s
  `smb2_service(POLLOUT) < 0` branch, which calls `teardownSeam()` itself and returns normally
  into `scheduleSeamTimeout()` — so an explicit end before teardown would cover only the first.
  `teardownSeam()` nils `transportBridge` on `eventLoopQueue`, the queue the pass runs on, so
  reading it in the `defer` is race-free and true on both paths. The marker's exact meaning is "the
  seam was gone when this pass ended": no false negatives, and one narrow false positive — a
  pass already dispatched when a teardown ran elsewhere on the queue — which the spec scenario
  states. The interval therefore includes teardown and context destruction on a terminal pass
  and says so via `terminal=1` metadata; the
  script reports terminal passes separately and excludes them from percentiles (D6). At most one
  terminal pass exists per connection. When the `guard let context` fails (context already
  destroyed), no pass interval is emitted; the dispatch interval was already closed by
  `beginServicePass`.

Reentrancy: the load-bearing property is that `os_signpost` never calls back into AMSMB2 code,
so it cannot re-enter `serviceFlagLock` or `TransportBridge.lock`; no lock-ordering or reentrancy
hazard exists, and the only cost inside a critical section while recording is a bounded,
non-blocking write into the signpost buffer (Apple does not promise it is lock-free or
allocation-free on first use, and this design does not rely on that).

"No behaviour change" is verified by the existing `TransportBridgeTests` (FIFO gather, cursor
advance, slice copy, return precedence), `TCPTransportAppleTests`, and `SMB2ServicingLoopTests`
(debounce coalesce-then-re-arm, teardown reset) passing unmodified.

### D5: Two red tests — the identifier contract and the begin/end pairing

1. `AMSMB2Tests/SignpostContractTests.swift` (under `#if canImport(Network)`) locates
   `docs/PROFILING.md` from `#filePath`, extracts the subsystem and category from the fenced
   instrument-filter block (fixed lines `subsystem: ro.SimpleKube.AMSMB2` / `category: Inbound`),
   and asserts equality with `InboundSignposts.subsystem` / `.category`, and asserts that each of
   the five signpost names appears verbatim in the doc and in `scripts/profile-summary.sh`. This
   encodes *why* the constants matter: the doc's filter must find the data, and a renamed signpost
   would otherwise show up as `count 0` in the summary, indistinguishable from "never fired".
2. A pairing test in `SMB2ServicingLoopTests` drives `consumeInboundReadySignal`,
   `beginServicePass` (now returning whether a signal was armed) and `teardownSeam` through the
   coalesce, re-arm and teardown-with-armed-signal sequences and asserts that every accepted
   signal is followed by exactly one armed clear, and that a clear with nothing armed returns
   `false`. Because `dispatchBegin` is emitted exactly when `consumeInboundReadySignal` returns
   `true` and `dispatchEnd` exactly when the clear returns `true`, this is the interval pairing
   invariant expressed at the seam the tests can reach. After `teardownSeam`, a further
   `beginServicePass()` returning `false` proves teardown performed the one armed clear.

Emission itself cannot be asserted in a unit test (no recording session), so the five names and
their metadata are proven by the capture task (D7) the same way QUIC interop was proven by the
interop gate.

### D6: Summary script — `xctrace export --xpath` + inline python3, with a committed fixture

`scripts/profile-summary.sh <bundle.trace | export-dir>`. Given a bundle, it exports
`/trace-toc/run[1]/data/table[@schema="time-profile"]` and
`/trace-toc/run[1]/data/table[@schema="os-signpost"]` to `time-profile.xml` / `os-signpost.xml`
in a temp dir; given a directory that already contains those files, it skips the export. Each
file is piped through a python3 heredoc that resolves `xctrace`'s `ref`/`id` back-references
(the export interns repeated values), reads columns by schema mnemonic and carries the schema
across the several `<node>` elements a real export splits one table into (only the first node
carries `<schema>`; the fixture pins that shape), aggregates samples by thread name, and computes per
signpost name (filtered to the subsystem) count, byte totals and size percentiles for the three
byte-carrying events, duration percentiles for the two intervals (terminal `ServicePass`
intervals — `terminal=1` — are counted and listed separately and excluded from the
percentiles), the coalescing ratio (`TransportRead` count ÷ `InboundChunk` count), the pump-hop
latency by walking both event streams in timestamp order and, for each `InboundChunk` of S
bytes, popping `TransportRead` events from a FIFO until their bytes sum to exactly S (reporting
`InboundChunk.ts − firstPopped.ts`; zero-byte reads are skipped explicitly; a sum that
overshoots S is reported as a pairing error, not silently skipped; with no `TransportRead`
events at all — a QUIC or pre-rc4 capture — the ratio and latency lines print `n/a` instead of
one error per chunk), the bytes still buffered at the end (`InboundChunk` total minus `RecvDrain`
total), and the derived throughput. Pairing by byte sum in FIFO order is exact for the TCP
transport because the pump is strictly sequential (one `receive()` outstanding at a time), so
chunks are handed over in read order and each chunk is a contiguous run of reads. Output is plain text tables. No third-party tooling; python3 ships
with Xcode's command-line tools.

Fixture: `test-fixtures/profiling/sample-export/` holds a small hand-written
`time-profile.xml` and `os-signpost.xml` in the `xctrace` export format (including `ref`
back-references) with known expected numbers — including at least one coalesced group (three
`TransportRead`s folding into one `InboundChunk`), one terminal `ServicePass`, the table split
across two `<node>` elements with only the first carrying `<schema>`, and an interned value
element inside a metadata cell (`<uint64 ref="…"/>`) — the two real-export shapes that a
single-node fixture had hidden — so the parsing, the pairing and the percentile arithmetic are
verifiable in this repo without a device or a bundle. The fixture is necessary but not
sufficient: during implementation two real-export shapes (the node split and the nested value
refs) were caught only by recording a throwaway macOS probe that emits the five names through
the same `os_signpost` calls and running the script on its bundle; anyone changing the parser
should repeat that check (`docs/PROFILING.md`, "Export and summarise"). The maintainer's local Debug bundle
(`../RandomPlayer/ios.trace`) is an additional operator-local check of the export step and the
"no signposts" path; it is not required by any spec scenario.

Behaviour on partial input: missing time-profile table → error exit; missing signpost table or
no matching subsystem → per-thread table only plus a "no AMSMB2 signposts" line, exit 0;
unreadable path → one-line error, non-zero.

Alternative: reading numbers off the Instruments GUI — not repeatable, not diffable.

### D7: The procedure is self-validating, and the baseline lives in the doc

`docs/PROFILING.md` sections: Purpose and what the numbers gate; Prerequisites (Xcode 26.6+,
Apple TV provisioned for development, RandomPlayer at a stated commit pinning the AMSMB2 version
under test, a Samba share with the named representative video); Build (Product ▸ Profile with the
tvOS device destination — Release per the shared scheme; the trace's process list MUST NOT
contain `libBacktraceRecording.dylib` or `libLogRedirect.dylib`, which is the Run-action
fingerprint that disqualified both existing bundles, checked with
`xcrun xctrace export --input <bundle> --xpath '/trace-toc/run[1]/processes'`); Instruments
(Time Profiler template, delete the Hangs track, do not add GCD, add `os_signpost` filtered to
the subsystem; equivalent `xcrun xctrace record --device <udid> --template 'Time Profiler'
--instrument os_signpost --time-limit 3m --launch -- <app>` form); Workload (open the named
video, 120 s steady-state playback, then five seeks at fixed offsets, 10 s each, stop); Export
and summarise (the script); Metrics table with definitions, including the two hops, the coalescing ratio, `TransportRead`
marked TCP-only, terminal passes, and the note that a `ServiceDispatch` interval closed by
teardown with no following pass is interval hygiene, not a lost wakeup (architect review, O5); Baseline (filled by the capture task: date, device, OS,
`xctrace version`, AMSMB2 version, the script output, and a note on observed stalls); Using the
baseline (before/after rule for #45/#46, same device, same video, same duration, three runs,
report the median).

The baseline numbers live in the doc, not in a tracked `.trace` (see Non-Goals); the issue
comment links to the doc's commit.

### D8: Versioning and the consumer-visible note

Additive, internal-only, no API change: ships in the next pre-release (6.0.0-rc4) so the
consumer app can re-pin and the baseline measures a tagged build. This repository has no
CHANGELOG file; the GitHub release notes for the rc4 tag carry the one consumer-visible fact,
that the library now emits signposts under `ro.SimpleKube.AMSMB2` / `Inbound`, and link
`docs/PROFILING.md`.

## Risks / Trade-offs

- [Signpost overhead while recording skews the hot path it measures] → Only integer metadata,
  events rather than intervals for the three high-frequency points, intervals only for the two
  per-pass points. The procedure records the signpost count so a reviewer can bound the overhead
  (≈1–2 µs per emit) against the pass duration.
- [`os_signpost` inside `serviceFlagLock` / the bridge `lock`] → Idle: one boolean read.
  Recording: a bounded, non-blocking buffer write that never calls back into AMSMB2, so no
  reentrancy or lock-ordering hazard (D4).
- [tvOS workload is manual; run-to-run variance] → Fixed video, fixed duration, fixed seek
  offsets, three runs, median reported. The doc calls out that a single run is not a baseline.
- [The Apple TV is the least convenient device to attach] → It is also the target where the
  op-count wins matter most (maintainer's choice). The doc notes the iPhone/iPad variant
  (identical steps, iOS destination) as a secondary target, without a recorded baseline.
- [`xctrace` export format drifts between Xcode versions] → The script pins the two xpaths and
  fails loudly; its parser is pinned by the committed fixture, the export step is exercised
  against a real bundle in the task list, and the doc records the `xctrace version` used.
- [Pump-hop pairing must survive coalescing, which is worst exactly when the hop is worst] →
  Pairing by equal byte count would drop every coalesced chunk and bias the latency toward the
  uncontended case. The script instead consumes `TransportRead`s in FIFO order until they sum
  to the chunk size, so every chunk pairs, and the coalescing ratio is reported alongside the
  latency as the direct measure of pump backlog. Exactness rests on the sequential pump; if a
  future transport delivers out of order, the overshoot check flags it rather than mis-pairing.
- [Terminal pass contains teardown] → Marked `terminal=1` on both failure paths via the
  `transportBridge == nil` read in the `defer`; the script excludes it from percentiles and
  lists it separately, so one outlier cannot move the #45/#46 numbers.
- [The consumer repo is outside this change's edit scope] → Nothing in RandomPlayer changes; the
  procedure only needs its existing Profile action and a re-pin to the rc that carries the
  signposts. The re-pin is an operator step in the doc, not a task here.
- [Baseline captured against rc4 while #43 shipped in rc1] → The inbound hot path is unchanged
  between rc1 and rc3 (the `git diff` commands in Context), and rc4 adds only the signposts, so
  rc4 is a faithful baseline for the deferred work.

## Open Questions

None that affect the specs or tasks. The representative video and the Samba share are named in
the doc by the operator at capture time and recorded alongside the baseline.
