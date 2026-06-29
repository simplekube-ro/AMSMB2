# parser-safety Specification

## Purpose
Harden response and request parsing against malformed or truncated server data. The MSRPC parser SHALL validate bounds at every offset adjustment, the IOCTL response parser SHALL rely on a reliable `output_count` guard instead of an unreliable `msync` memory probe, MSRPC request padding SHALL use byte-count alignment, and pipelined I/O SHALL handle partial failure correctly without returning partial or out-of-order data.

## Requirements

### Requirement: IOCTL response parser does not use msync memory probe
The IOCTL response parser SHALL NOT use the `msync` memory probe to validate the output buffer. The `output_count > 0` guard together with a non-nil `output` pointer is sufficient, and the behavior SHALL be identical on Darwin and Linux.

#### Scenario: msync block is removed
- **WHEN** `DecodableResponse.init(_:SMB2Client, _:)` parses an IOCTL reply
- **THEN** the `#if canImport(Darwin)` msync block SHALL be absent and the parser SHALL rely only on the `guard reply.output_count > 0, let output = reply.output` check

#### Scenario: Zero output_count returns empty data
- **WHEN** `DecodableResponse.init` is given a reply with `output_count == 0`
- **THEN** it SHALL return empty data without performing any msync probe

#### Scenario: Darwin and Linux behave identically
- **WHEN** the IOCTL response parser runs on Darwin versus Linux for the same reply
- **THEN** the parsing behavior SHALL be identical (no Darwin-only msync guard)

### Requirement: MSRPC parser bounds-checks all offset adjustments
The MSRPC share-enumeration parser SHALL validate that each offset adjustment stays within the buffer before applying it, and SHALL throw `POSIXError(.EINVAL)` on any bounds violation, consistent with the existing checks.

#### Scenario: Name-alignment padding is bounds-checked
- **WHEN** the parser is about to apply `offset += 2` padding for name alignment
- **THEN** it SHALL first verify `offset + 2 <= data.count`, and SHALL throw `POSIXError(.EINVAL)` if the check fails

#### Scenario: Comment-alignment padding is bounds-checked
- **WHEN** the parser is about to apply `offset += 2` padding for comment alignment
- **THEN** it SHALL first verify `offset + 2 <= data.count`, and SHALL throw `POSIXError(.EINVAL)` if the check fails

#### Scenario: Truncated data at name padding throws EINVAL
- **WHEN** the parser is given truncated data that overruns at the name padding adjustment
- **THEN** it SHALL throw `POSIXError(.EINVAL)`

#### Scenario: Truncated data at comment padding throws EINVAL
- **WHEN** the parser is given truncated data that overruns at the comment padding adjustment
- **THEN** it SHALL throw `POSIXError(.EINVAL)`

#### Scenario: Valid data still parses
- **WHEN** the parser is given well-formed share-enumeration data
- **THEN** it SHALL parse the shares correctly without throwing (regression)

### Requirement: MSRPC request padding uses byte-count alignment
The MSRPC request builder SHALL compute the padding after `serverNameData` from the byte count for 4-byte NDR alignment, not from the character count.

#### Scenario: Padding is computed from byte count
- **WHEN** the request builder appends padding after `serverNameData`
- **THEN** the padding SHALL be derived from the byte count to achieve 4-byte NDR alignment, and SHALL NOT be based on `serverNameLen % 2` (character-count alignment, which is always even in bytes)

#### Scenario: Share enumeration still works
- **WHEN** a share enumeration request is built and sent to a server
- **THEN** share enumeration SHALL continue to work correctly (MSRPC regression)

### Requirement: Pipelined read discards partial window data on error
When any chunk in a pipelined read window fails, the whole window's results SHALL be discarded, the read offset SHALL NOT advance, and the originating error SHALL propagate to the caller.

#### Scenario: Failing chunk discards the window
- **WHEN** `collector.get(index: i)` throws for any index in the current window
- **THEN** all results from the current window SHALL be discarded and `currentOffset` SHALL NOT advance for that window

#### Scenario: Error propagates to caller
- **WHEN** a chunk in the current read window fails
- **THEN** the error from the failing chunk SHALL propagate to the caller

#### Scenario: Successful pipelined read completes correctly
- **WHEN** a file is read via pipelined reads with no chunk failures
- **THEN** the read SHALL complete correctly and return the full file contents (regression)

### Requirement: Pipelined write throws on first chunk error
When a chunk in a pipelined write window fails, the write SHALL throw immediately, the write offsets SHALL NOT advance, and the indeterminate-state consequence SHALL be documented.

#### Scenario: Failing chunk does not advance offsets
- **WHEN** a chunk in the current write window fails
- **THEN** `currentOffset` and `dataOffset` SHALL NOT advance for that window and the error SHALL be thrown

#### Scenario: Partial-write state is documented
- **WHEN** a pipelined write fails partway through
- **THEN** the API documentation SHALL state that partial writes leave the file in an indeterminate state
