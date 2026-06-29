## Capability: parser-safety

MSRPC parser validates bounds at every offset adjustment; IOCTL response parser uses output_count guard without unreliable msync; pipelined I/O handles partial failure correctly.

## Requirements

### R1: msync memory probe must be removed
- The `#if canImport(Darwin)` msync block in `DecodableResponse.init(_:SMB2Client, _:)` must be deleted
- The `guard reply.output_count > 0, let output = reply.output` check is sufficient
- Behavior on Linux (no msync guard) and Darwin must be identical

### R2: MSRPC parser must bounds-check all offset adjustments
- Before `offset += 2` padding for name alignment (line ~74): check `offset + 2 <= data.count`
- Before `offset += 2` padding for comment alignment (line ~97): check `offset + 2 <= data.count`
- On bounds violation: throw `POSIXError(.EINVAL)` (consistent with existing checks)

### R3: MSRPC request padding must use byte-count alignment
- The padding after `serverNameData` must be based on byte count for 4-byte NDR alignment
- Not based on `serverNameLen % 2` (character count, which is always even in bytes)

### R4: Pipelined read must not return partial window data on error
- When `collector.get(index: i)` throws for any index, all results from the current window must be discarded
- `currentOffset` must NOT advance for the failed window
- The error from the failing chunk must propagate to the caller

### R5: Pipelined write must throw on first chunk error
- `currentOffset` and `dataOffset` must NOT advance for the failed window
- Partial writes must be documented as leaving the file in indeterminate state

## Verification

- Unit test: MSRPC parser with truncated data (offset overrun at name padding) throws EINVAL
- Unit test: MSRPC parser with truncated data (offset overrun at comment padding) throws EINVAL
- Unit test: MSRPC parser with valid data still parses correctly (regression)
- Unit test: `DecodableResponse.init` with `output_count == 0` returns empty data (msync not needed)
- Integration test: pipelined read of a file completes correctly (regression)
- Integration test: share enumeration still works (MSRPC regression)
