## MODIFIED Requirements

### Requirement: Inbound path signposts

On Apple platforms, when a seam transport is active, the library SHALL emit `os_signpost` data
under a single subsystem `ro.SimpleKube.AMSMB2` and category `Inbound` at exactly these points:

- `TransportRead` — an event each time the TCP transport (only; the QUIC transport is not
  instrumented by this change) receives a chunk from the network stack, on the network stack's
  own queue, carrying the chunk's byte count. Zero-length reads are skipped before the event is
  emitted. The transport hands each read to the bridge inside
  the same callback, so for the lifetime of the connection every `TransportRead` pairs with
  exactly one `InboundChunk`, the ratio of `TransportRead` to `InboundChunk` events is 1.00 by
  construction, and the delay between the two is the in-callback hand-off (the bridge lock and
  the append), not an executor hop; the only unpaired read possible is one that races the
  bridge's teardown (the bridge has closed but the transport has not yet stopped reading), which
  the bridge drops. Before
  the inbound push-conversion (issue #45) a cooperative-pool pump task sat between the two —
  several reads could then be handed over as one chunk and the delay was that task's hop — and
  the baseline captured with that path records what the hop cost.
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
version, and AMSMB2 version they were captured against, and — once the inbound push-conversion
has landed — an After section holding the same numbers captured with it under the same
procedure, the delta against the Baseline, and the rule for reading that delta (the
cooperative-pool per-thread shares, the dispatch and pass percentiles, active throughput and
stalls are the comparison; the pump-hop row is the residual in-callback hand-off and the
coalescing ratio is 1.00 by construction after the conversion).

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

#### Scenario: Push-conversion delta is recorded

- **WHEN** the inbound push-conversion has landed and the operator has captured three runs with
  it by the same procedure on the same device
- **THEN** the document's After section holds the median run's script output, the capture
  context (date, device, OS, `xctrace` version, AMSMB2 version, RandomPlayer commit), and a
  delta table against the Baseline for the per-thread shares, dispatch and pass percentiles,
  active throughput and stalls, computed by the same script; a single trailing `TransportRead`
  left unpaired by bridge teardown at the end of a run is not a pairing error
