## MODIFIED Requirements

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

After the `InboundChunk` size line the script SHALL print a ceiling line: the number of
`InboundChunk` events whose size equals the maximum observed chunk size, with their share of the
chunk count (three decimals) and of the byte total (two decimals), followed by the share of chunks
and of bytes at or above each of 64 KB, 128 KB, 256 KB, 512 KB and 1 MB, in that order, on one
line, so that a reader can tell whether the transport's receive length bound the capture. These
shares are printed to finer precision than the per-thread table's one decimal because an at-cap
chunk share is a fraction of a percent while its byte share is whole percents. When there are no
`InboundChunk` events the line SHALL print `ceiling: n/a`. The line measures the transport's
receive length only where the coalescing ratio is 1.00 (a TCP capture of 6.0.0-rc5 or later): in a
capture whose reads were coalesced, or whose chunks came from a transport that emits no
`TransportRead`, the maximum is a coalesced maximum, and the coalescing-ratio line the script
already prints is what qualifies the ceiling line.

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

#### Scenario: Ceiling line from the committed fixtures

- **WHEN** the script is run on each of the committed fixtures, including the fixture whose chunk
  sizes straddle the 64 KB, 128 KB, 256 KB, 512 KB and 1 MB thresholds
- **THEN** each output contains exactly one ceiling line whose at-max count and whose ten
  threshold shares equal the values computed by hand from that fixture's chunk sizes in its
  `expected.txt` — non-zero for at least three of the five thresholds on the straddling fixture —
  and every other line is unchanged

#### Scenario: Ceiling line on a real capture

- **WHEN** the script is run on a TCP bundle whose coalescing ratio is 1.00 and in which some
  chunks reached a receive length that is one of the five printed thresholds
- **THEN** the ceiling line's maximum size equals the receive length in force for that build and
  the at-or-above share for that threshold equals the at-max share

## ADDED Requirements

### Requirement: Receive-length decision record

The profiling document SHALL hold a dated subsection recording the decision for the TCP
transport's maximum receive length: the capture set it was computed from (bundles, AMSMB2
version, device, server), the per-run ceiling table produced by the summary script, the reading of
what raising and lowering the value could change in chunk count and per-chunk chain time — stating
which of those figures are measured and which are derived by splitting each over-cap chunk at a
hypothetical lower cap — the decision, and the rule under which the question is re-opened together
with the arithmetic that sets the rule's threshold. Because the record decides *not* to change the
transport, it SHALL say so explicitly, so that it is not read as a change that skipped the
before/after delta the document requires of inbound-path changes. The transport source SHALL
reference the subsection in the comment on the option.

#### Scenario: Decision is traceable

- **WHEN** a contributor reads the transport's receive-length comment
- **THEN** they are pointed at the subsection, and every number in the subsection's decision is
  either a value the summary script prints for one of the named bundles or is labelled as derived
  from those values, with the derivation stated

#### Scenario: Revisit condition is checkable from one line

- **WHEN** a later capture is summarised with the script
- **THEN** its ceiling line alone is enough to test the subsection's revisit rule
