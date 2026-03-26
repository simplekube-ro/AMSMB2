## Why

A code review identified 4 robustness issues in the parsing and I/O pipeline. These affect how the library handles malformed server responses, partial I/O failures, and pointer validation. A malicious or buggy SMB server could trigger out-of-bounds reads in the MSRPC parser, silent data corruption in pipelined reads, or incorrect padding in share enumeration requests.

## What Changes

- **Remove `msync` memory validity probe** (Parsers.swift:91-98): The `msync` call is unreliable for validating heap pointers and non-portable (only on Darwin). Replace with a check on `reply.output_count > 0` alone (which is already done on line 87), and remove the `msync` block entirely. If libsmb2 returns invalid pointers, that's a libsmb2 bug to fix upstream.
- **Fix pipelined I/O partial failure handling** (FileHandle.swift:354-470): When a chunk fails mid-window, `result` may already contain data from earlier chunks in the same window. On error, discard the partial window's results and throw immediately without advancing offsets. Document that partial writes leave the file in an indeterminate state.
- **Add bounds checking to MSRPC parser** (MSRPC.swift:59-109): The alignment padding (`offset += 2`) on lines 73-76 and 95-98 happens without checking that `offset` is still within `data.count`. Add bounds checks before each padding adjustment.
- **Fix MSRPC padding alignment** (MSRPC.swift:222): The padding calculation uses `serverNameLen % 2` (character count) when it should use byte-count alignment. An odd character count means even bytes (no padding needed); an even character count means even bytes (also no padding). The current logic is inverted. Fix to align on 4-byte boundary based on `serverNameData.count`.

## Capabilities

### New Capabilities
- `parser-safety`: MSRPC parser validates bounds at every offset adjustment; IOCTL response parser uses output_count guard without unreliable msync heuristic; pipelined I/O correctly handles partial failure

### Modified Capabilities

## Impact

- **Parsers.swift**: Remove `msync` block (lines 91-98)
- **FileHandle.swift**: Fix `pipelinedRead` and `pipelinedWrite` error/offset handling
- **MSRPC.swift**: Add bounds checks in `NetShareEnumAllLevel1` parser, fix padding in `NetShareEnumAllRequest`
- **No public API changes**
- **Behavioral**: Operations that previously could silently corrupt data or crash on malformed responses now fail cleanly with errors
