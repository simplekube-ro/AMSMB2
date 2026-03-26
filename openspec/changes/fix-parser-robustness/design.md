## Context

The AMSMB2 library parses binary protocol data from SMB2 servers in several places: MSRPC share enumeration responses (`MSRPC.swift`), IOCTL response data (`Parsers.swift`), and pipelined file I/O result collection (`FileHandle.swift`). These parsers trust server data more than they should.

## Goals / Non-Goals

**Goals:**
- Every offset adjustment in parsers must be bounds-checked before dereferencing
- Remove unreliable pointer validation heuristics (`msync`)
- Pipelined I/O must handle partial failures without corrupting results
- MSRPC request padding must use byte-count alignment, not character-count

**Non-Goals:**
- Full protocol fuzzing (future work, possibly with `test-infrastructure`)
- Fixing libsmb2's own parsers (out of scope — those are in C)
- Changing the pipelined I/O window size or strategy

## Decisions

### D1: Remove msync entirely, rely on output_count guard

**Choice**: Delete the `#if canImport(Darwin)` msync block. The guard on line 87 (`guard reply.output_count > 0, let output = reply.output`) is the correct check. If `output_count > 0` and `output` is non-nil, we trust the pointer. If libsmb2 lies about this, it's a libsmb2 bug.

**Rationale**: `msync` only works for memory-mapped regions, not heap allocations. It gives false negatives (valid heap pointer rejected) and false positives (garbage pointer on a valid page accepted). It's worse than no check at all because it creates a false sense of safety.

### D2: Pipelined read — discard partial window on error

**Choice**: In `pipelinedRead`, when iterating `collector.get(index: i)` and any index throws, discard all results from the current window (don't append partial results) and throw. Don't advance `currentOffset` for the failed window.

**Alternative**: Keep partial results and return them with the error. Rejected — partial results are confusing and callers can't distinguish "got 3 of 4 chunks" from "got all 4".

### D3: Pipelined write — document indeterminate state on error

**Choice**: On write failure, throw immediately. Document that partial writes leave the remote file in an indeterminate state. The caller should truncate or delete the file.

**Rationale**: Rolling back a partial write requires reading the original data first (not available) or truncating (which may fail if the connection is broken). The honest answer is "the file is in an unknown state."

### D4: MSRPC bounds checks — fail with EINVAL on overrun

**Choice**: Before each `offset += 2` padding adjustment, check `offset + 2 <= data.count`. If not, throw `POSIXError(.EINVAL)`. This matches the existing error pattern used for the main offset checks on lines 62-63 and 83-84.

### D5: MSRPC padding — SKIPPED (existing code is correct)

**Original analysis was wrong.** The existing `serverNameLen % 2 == 1` check IS correct 4-byte NDR alignment: `serverNameLen * 2 % 4 == 0` ⟺ `serverNameLen % 2 == 0`, so odd `serverNameLen` correctly triggers 2 extra bytes of padding. Verified by tracing through multiple server name lengths. No change needed.

## Risks / Trade-offs

**[Risk] Removing msync could allow crashes on invalid pointers** → The guard on `output_count > 0` is the correct defense. If libsmb2 returns count > 0 with an invalid pointer, that's a libsmb2 bug. We should not paper over it with unreliable heuristics.

**[Risk] Stricter MSRPC bounds checking could reject responses that currently parse** → Only if the server sends malformed responses that happen to not crash today. Rejecting them is correct behavior.
