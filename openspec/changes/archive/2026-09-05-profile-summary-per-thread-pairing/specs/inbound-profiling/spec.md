## MODIFIED Requirements

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
latency from a `TransportRead` to its `InboundChunk` — paired per delivery thread for captures
taken since the inbound push-conversion, or by consuming coalesced reads in a global byte-sum
FIFO for captures taken before it, the document stating which captures need which mode and
that the attach carry-over chunk and the teardown-race read are counted, not errors —
dispatch-latency
percentiles, service-pass count and duration with terminal passes reported separately, stalls
during the fill and playback; `TransportRead` marked as TCP-only), how to read a dispatch interval that is closed by
teardown with no following pass, how to run the summary script on the resulting bundle
(including the pairing mode the bundle's generation needs), and a
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
ratio, the pump-hop latency distribution, the bytes still buffered at the end (total
`InboundChunk` minus total `RecvDrain`), and the derived throughput (bytes drained per second of
wall-clock, both over the whole span and over the active time with idle gaps longer than one
second excluded).

The pump-hop latency SHALL be derived in one of two pairing modes, selected by the operator and
named in the output so that a summary can be read on its own:

- **Per-thread** (the default, for captures of 6.0.0-rc5 or later, where a read and its chunk
  are emitted back to back on the same thread): `TransportRead` and `InboundChunk` events are
  grouped by the thread that emitted them and paired within each thread in timestamp order, at
  most one read pending per thread; a chunk pairs with the pending read of equal byte count and
  the latency is the chunk time minus that read's time. A chunk with no read pending on its
  thread is reported as a chunk without a read (an attach carry-over, a read signpost the
  recorder dropped, or a chunk from a transport that does not emit `TransportRead`), and a read
  that is followed by another read, or by the end of the capture, with no chunk in between is
  reported as a read without a chunk; both are counted and neither is a pairing error. A chunk
  whose pending read has a different byte count is a pairing error, counted and printed with
  both byte counts and the thread, and consumes both the read and the chunk, so that every
  chunk is exactly one of paired, without a read, or an error, and every non-zero read is
  exactly one of paired, without a chunk, or an error. In this mode the script SHALL also print the number
  of distinct threads that emitted `TransportRead` or `InboundChunk`, and SHALL NOT print a
  reads-per-chunk distribution (every pair is one read to one chunk by construction).
- **Global** (explicitly selected, for captures before the inbound push-conversion, where the
  chunk was appended from a pump task on another thread): `TransportRead` events are consumed
  across all threads in timestamp order until their bytes sum to each `InboundChunk`, measuring
  from the first consumed read; overshoot and underflow are pairing errors; the reads-per-chunk
  distribution is printed.

In both modes zero-byte `TransportRead` events are skipped and counted, and all other output
lines are identical between the modes. When the input contains no `TransportRead` events (a QUIC
capture, or a bundle from a build before this change) the coalescing ratio and pump-hop latency
SHALL be reported as not available rather than as pairing errors, in either mode. An
unrecognised pairing mode SHALL be rejected with a one-line usage message and a non-zero exit.
It SHALL work with the `xctrace` shipped in Xcode 26 and SHALL fail with a clear message, not a
stack trace, when the input has no time-profile table, is not readable, or a signpost row of the
subsystem carries no thread.

#### Scenario: Summary from the committed fixture

- **WHEN** the script is run in per-thread mode on the synthetic exported-XML fixture committed
  under `test-fixtures/` whose reads and chunks are emitted on their own threads, in global mode
  on the synthetic fixture whose chunks are emitted on a pump thread, and in per-thread mode on
  the synthetic fixture that has no `TransportRead` events
- **THEN** each prints the per-thread table and the five per-signpost summaries with the values
  its fixture was written to produce, and running any of them twice yields identical output

#### Scenario: Interleaved connections pair exactly per thread

- **WHEN** two threads each emit a `TransportRead` and then its `InboundChunk`, and the second
  thread's read and chunk fall between the first thread's read and chunk, with different byte
  counts
- **THEN** per-thread mode reports two pairs, each with the latency between the read and the
  chunk of its own thread, and no pairing error, whereas global mode reports an overshoot and an
  underflow for the same rows

#### Scenario: Chunks without a read and reads without a chunk are counted, not errors

- **WHEN** a per-thread summary meets an `InboundChunk` with no `TransportRead` pending on its
  thread, or a `TransportRead` that is followed on its thread by another `TransportRead` or by
  the end of the capture before any `InboundChunk`
- **THEN** the chunk is counted as a chunk without a read and the read as a read without a
  chunk, both are printed next to the pair count, and the pairing-error count is unaffected

#### Scenario: Byte mismatch on one thread is a pairing error

- **WHEN** in per-thread mode an `InboundChunk` arrives on a thread whose pending
  `TransportRead` has a different byte count
- **THEN** the script counts one pairing error, prints it with both byte counts and the thread,
  does not pair that read with any later chunk, and counts neither the read nor the chunk in
  the without-a-chunk or without-a-read totals

#### Scenario: Pairing mode is explicit in the output

- **WHEN** the script is run without a pairing option, or with the global mode selected
- **THEN** the output names the mode used (per-thread with the delivery-thread count, or global)
  on a line of its own before the pump-hop latency line

#### Scenario: Summary from a bundle without signposts

- **WHEN** the script is run on a bundle or export that has a time-profile table but no
  `ro.SimpleKube.AMSMB2` signposts
- **THEN** it prints the per-thread CPU table, reports that no matching signposts were found, and
  exits successfully

#### Scenario: Unreadable input

- **WHEN** the script is run on a path that is neither a readable `.trace` bundle nor an export
  directory containing a time-profile table, or the pairing option names an unknown mode
- **THEN** it exits non-zero with a one-line explanation
