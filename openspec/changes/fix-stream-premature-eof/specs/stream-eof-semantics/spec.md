## ADDED Requirements

### Requirement: EOF is reported only after the producer is exhausted

`AsyncInputStream.read(_:maxLength:)` SHALL report end-of-stream (`read` returns `0`, status
becomes `.atEnd`) **only** when the underlying `AsyncSequence` producer has finished (its iterator
returned `nil`) **and** every buffered byte has been consumed. A transient buffer drain — the
consumer momentarily out-pacing the prefetch producer while the producer is still running — SHALL
NOT be reported as EOF.

#### Scenario: Drained buffer with a running producer reports would-block, not EOF

- **WHEN** the consumer has read all currently-buffered bytes but the producer's iterator has not
  yet returned `nil`
- **THEN** `read(_:maxLength:)` returns `-1` (would-block) and leaves `streamStatus == .open`
- **AND** `streamError` is `nil`
- **AND** a subsequent `read(_:maxLength:)` returns the next bytes once the prefetch task appends
  them (no `0`/`.atEnd` is observed in between)

#### Scenario: EOF after the producer finishes

- **WHEN** the producer's iterator has returned `nil` and the consumer has read all buffered bytes
- **THEN** `read(_:maxLength:)` returns `0` and `streamStatus == .atEnd`

#### Scenario: Empty source reports EOF immediately

- **WHEN** the source `AsyncSequence` yields no elements (its iterator returns `nil` on the first
  `next()`)
- **THEN** the first `read(_:maxLength:)` after the producer finishes returns `0` with
  `streamStatus == .atEnd` (no would-block hang)

### Requirement: Consumer honors the would-block contract

The streamed-upload consumer (`SMB2Manager.write(client:from:toPath:)`) SHALL treat a `-1` return
from `read(_:maxLength:)` as *would-block* — retrying after `await Task.yield()` — **only** when
`streamStatus` is `.open` or `.reading` **and** `streamError == nil`. It SHALL treat a `0` return as
end-of-stream and stop. It SHALL surface a genuine producer error (`streamStatus == .error`) as a
thrown `streamError ?? POSIXError(.EIO)`. A `-1` with any other status (`.closed`, `.notOpen`,
`.opening`) is terminal and SHALL stop the loop without retrying (it MUST NOT be treated as
would-block, which would hang).

#### Scenario: Would-block is retried, not thrown

- **WHEN** `read(_:maxLength:)` returns `-1` while `streamStatus == .open` and `streamError == nil`
- **THEN** the consumer yields (`await Task.yield()`) and re-reads instead of throwing
- **AND** no `0`-byte `pwrite` is issued for the would-block result

#### Scenario: Producer error surfaces as a thrown POSIXError

- **WHEN** the producer's iterator throws mid-stream
- **THEN** `prefetchData()` sets `streamStatus == .error` **and** stores the thrown error in
  `streamError` (it is no longer dropped)
- **AND** the consumer throws the stored `streamError` (the actual error, not a generic `EIO`
  fallback) and stops the upload
- **AND** the consumer does not loop indefinitely on the `-1` return

### Requirement: Streamed upload transfers all bytes and round-trips byte-equal

A streamed upload of `N` bytes through `AsyncInputStream` SHALL transfer all `N` bytes to the
destination, including when `N` exceeds the in-memory prefetch window (~5 MiB). Reading the
uploaded file back SHALL yield bytes equal to the source.

#### Scenario: Upload larger than the prefetch window is not truncated

- **WHEN** a file with `N > 5 MiB` is uploaded via `write(stream:toPath:)`
- **THEN** the destination file's size equals `N` (no truncation at `5242880`)
- **AND** reading the file back yields bytes byte-equal to the source

#### Scenario: Small upload still succeeds (no regression)

- **WHEN** a file with `N < 5 MiB` is uploaded via `write(stream:toPath:)`
- **THEN** the destination file's size equals `N` and the read-back is byte-equal

#### Scenario: Repeated random-size uploads all round-trip

- **WHEN** `SMB2ManagerTests.testStreamUploadDownload` runs repeatedly with random sizes spanning
  below and above the prefetch window
- **THEN** every run transfers all bytes and the byte-equal assertion passes (none truncate at
  `5242880`)
