## Purpose

Make the SMB-over-NIO inbound path measurable with real signal: low-overhead signpost intervals
and events at the five points that define the streaming-read hot path, a repeatable Release-build
on-device capture procedure with a recorded baseline, and tooling that turns any capture into the
same comparable numbers, so that the deferred transport work (push-conversion, receive-length
tuning) is judged by a before/after delta rather than by an observer-noise trace.

## ADDED Requirements

### Requirement: Inbound path signposts

On Apple platforms, when a seam transport is active, the library SHALL emit `os_signpost` data
under a single subsystem `ro.SimpleKube.AMSMB2` and category `Inbound` at exactly these points:

- `TransportRead` — an event each time the TCP transport (only; the QUIC transport is not
  instrumented by this change) receives a chunk from the network stack, on the network stack's
  own queue, carrying the chunk's byte count. When the pump is not keeping up, several
  `TransportRead` chunks are handed to the bridge as one `InboundChunk` whose size is their sum;
  the delay from the first of those reads to that `InboundChunk` is the cooperative-pool pump hop
  that the inbound push-conversion (issue #45) removes, and the ratio of `TransportRead` to
  `InboundChunk` events is how far the pump falls behind.
- `InboundChunk` — an event each time the transport delivers a non-empty inbound chunk to the
  bridge, carrying the chunk's byte count.
- `ServiceDispatch` — an interval that begins when an inbound-ready signal arms a service pass
  (the debounce accepts the signal) and ends when the armed signal is cleared, either because the
  pass begins on the event-loop queue or because the seam is torn down first; at most one such
  interval is open per client at any time, and every begin is matched by exactly one end.
- `ServicePass` — an interval spanning one signal-driven service pass (libsmb2 service, outbound
  flush, timer reschedule). A pass that tears the seam down, on either failure path (the service
  call or the outbound flush), includes that teardown and carries a terminal marker so that the
  summary tooling can report it separately and keep it out of the duration percentiles.
- `RecvDrain` — an event each time libsmb2 drains the inbound store, carrying the number of bytes
  that call copied (zero means EOF) or a distinguishable would-block marker.

The signposts SHALL NOT change any observable behaviour of the inbound path: the bytes delivered,
the drain return-value precedence (closed → bytes → EOF → error → would-block), the
lost-wakeup-free debounce, and teardown are unchanged. When no instrument is recording, each
instrumentation point SHALL cost no more than one signpost-enablement check (no allocation, no
argument formatting). On platforms without `Network` (Linux) nothing is emitted and nothing
additional is compiled, in the library or in the test target.

#### Scenario: Chunk and drain events carry byte counts

- **WHEN** a recording with the `os_signpost` instrument filtered to subsystem
  `ro.SimpleKube.AMSMB2` is active while a file is streamed and the connection is then closed
- **THEN** every `TransportRead` and `InboundChunk` event reports the byte count of its chunk,
  every `RecvDrain` event reports the bytes that drain call copied (a zero means EOF; would-block
  is a distinct marker), the total `InboundChunk` bytes equal the total `TransportRead` bytes
  (coalescing changes counts, never bytes), and the total `RecvDrain` bytes never exceed the total
  `InboundChunk` bytes (the difference is what was still buffered when the recording stopped)

#### Scenario: Dispatch and pass intervals bracket the hop

- **WHEN** a burst of chunks arrives while no service pass is pending
- **THEN** the trace contains exactly one `ServiceDispatch` interval for the burst, which ends
  when the pass begins on the event-loop queue and is followed by exactly one `ServicePass`
  interval; if the context was already destroyed when the pass was dequeued, the dispatch interval
  still ends and no pass interval is emitted

#### Scenario: Terminal pass is marked

- **WHEN** a service pass ends after the seam has been torn down — because that pass's service
  call or outbound flush failed, or because teardown ran while the pass was already dispatched
- **THEN** that pass's `ServicePass` interval carries the terminal marker; a pass that ends with
  the seam still up never carries it, so at most the passes around one teardown are marked

#### Scenario: Teardown closes a pending dispatch interval

- **WHEN** the seam is torn down while an inbound-ready signal is armed but its pass has not begun
- **THEN** the `ServiceDispatch` interval is closed by the teardown, the debounce flag is reset,
  and a reconnect on the same client emits a fresh interval on its first signal

#### Scenario: Begin and end are paired one-to-one

- **WHEN** the unit suite drives the debounce through coalesce (several signals before one
  pass), re-arm (a signal during a pass) and teardown-with-armed-signal sequences
- **THEN** every accepted signal is followed by exactly one armed clear, and a clear with no
  armed signal reports that nothing was armed, so no dispatch interval can be begun twice or
  ended twice

#### Scenario: Instrumentation is inert when not recording

- **WHEN** the full unit suite runs with no Instruments session attached
- **THEN** every existing transport-bridge, transport, and servicing-loop test passes unchanged
  and no signpost data is produced

#### Scenario: Identifier contract is pinned to the procedure

- **WHEN** a unit test reads the instrument filter named in the profiling procedure document
- **THEN** the subsystem and category it names are byte-identical to the constants the library
  emits under, and each of the five signpost names the library emits appears verbatim in the
  document and in the summary script, so renaming any of them without updating the others fails
  the suite

### Requirement: Release-build on-device capture procedure

The repository SHALL contain a profiling procedure document (`docs/PROFILING.md`), linked from
the README documentation index, that lets an operator reproduce the streaming-read baseline
capture end to end. It SHALL specify: the build configuration (Release, via the consumer app's
Profile action — never a debugger launch; the document SHALL name the debugger-injected libraries
whose presence in a trace's process list disqualifies it and the export command that lists
them), the physical device and OS versions to record (primary target: Apple TV), the
Instruments configuration (Time Profiler with the Hangs and GCD instruments removed, plus the
`os_signpost` instrument filtered to `ro.SimpleKube.AMSMB2`), the equivalent `xctrace record`
command line, the workload (one cache fill: the consumer app caches a video on open and plays
the local copy, so the operator attaches the recording to the idle app and then opens an
uncached representative video of stated size, leaving it until the fill completes),
the metrics to
record (average CPU cores, per-thread CPU distribution with the cooperative-pool threads called
out, sustained throughput in MB/s, inbound chunk-size distribution, the `TransportRead`-to-`InboundChunk` coalescing ratio, pump-hop
latency from the first coalesced `TransportRead` to its `InboundChunk`, dispatch-latency
percentiles, service-pass count and duration with terminal passes reported separately, stalls
during the fill and playback; `TransportRead` marked as TCP-only), how to read a dispatch interval that is closed by
teardown with no following pass, how to run the summary script on the resulting bundle, and a
Baseline section holding the recorded numbers together with the date, device, OS, `xctrace`
version, and AMSMB2 version they were captured against.

#### Scenario: Operator reproduces a capture

- **WHEN** an operator with a provisioned Apple TV and the RandomPlayer project follows the
  document from a clean checkout
- **THEN** they produce a `.trace` bundle whose process list contains no debugger-injected
  library, whose instrument set is Time Profiler and `os_signpost` only, and which contains all
  five signpost names

#### Scenario: Baseline is recorded and discoverable

- **WHEN** a contributor evaluating the push-conversion or the receive-length sweep opens the
  document
- **THEN** they find the baseline numbers, the capture context (date, device, OS, `xctrace`
  version, AMSMB2 version), and the instruction that neither follow-up merges without a
  before/after delta computed by the same procedure and script

### Requirement: Trace summary tooling

The repository SHALL contain a script (`scripts/profile-summary.sh`) that prints the comparison
numbers without the Instruments GUI. It SHALL accept either a `.trace` bundle (which it exports
with `xctrace`) or a directory of already-exported time-profile and signpost XML (so the parsing
is reproducible without a device or a bundle). From the time-profile samples it SHALL print the
total sample count and a per-thread table (thread name, samples, share of total) that makes the
cooperative-pool signature visible; from the signpost data, per signpost name filtered to the
subsystem, the count, and for `TransportRead`, `InboundChunk` and `RecvDrain` the byte total and
size distribution (min / median / p95 / max), for `ServiceDispatch` and `ServicePass` the
duration distribution (min / median / p95 / max) with terminal passes counted and listed
separately and excluded from the percentiles, the `TransportRead`-to-`InboundChunk` coalescing
ratio, the pump-hop latency distribution derived by consuming `TransportRead` events in order
until their bytes sum to each `InboundChunk` and measuring from the first consumed read, the
bytes still buffered at the end (total `InboundChunk` minus total `RecvDrain`), and the derived
throughput (bytes drained per second of wall-clock, both over the whole span and over the active
time with idle gaps longer than one second excluded). When the input contains no `TransportRead`
events (a QUIC capture, or a bundle from a build before this change) the coalescing ratio and
pump-hop latency SHALL be reported as not available rather than as pairing errors. It SHALL work
with the `xctrace` shipped in Xcode 26 and SHALL fail with a clear message, not a stack trace,
when the input has no time-profile table or is not readable.

#### Scenario: Summary from the committed fixture

- **WHEN** the script is run on the synthetic exported-XML fixture committed under
  `test-fixtures/`
- **THEN** it prints the per-thread table and the five per-signpost summaries with the values
  the fixture was written to produce, and running it twice yields identical output

#### Scenario: Summary from a bundle without signposts

- **WHEN** the script is run on a bundle or export that has a time-profile table but no
  `ro.SimpleKube.AMSMB2` signposts
- **THEN** it prints the per-thread CPU table, reports that no matching signposts were found, and
  exits successfully

#### Scenario: Unreadable input

- **WHEN** the script is run on a path that is neither a readable `.trace` bundle nor an export
  directory containing a time-profile table
- **THEN** it exits non-zero with a one-line explanation
