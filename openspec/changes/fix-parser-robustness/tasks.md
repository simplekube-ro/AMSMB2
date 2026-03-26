## 1. Tests First (TDD Red Phase)

- [ ] 1.1 Add test `testMSRPCParserBoundsCheckNamePadding`: construct a `Data` payload that is valid up to the name string but truncated at the alignment padding point, assert parsing throws `POSIXError` with `.EINVAL`
- [ ] 1.2 Add test `testMSRPCParserBoundsCheckCommentPadding`: same as above but truncated at comment alignment padding
- [ ] 1.3 Add test `testMSRPCParserValidPayload`: construct a valid NetShareEnumAll response payload, assert it parses correctly with expected share names (regression test)
- [ ] 1.4 Add test `testDecodableResponseEmptyOutput`: verify that `output_count == 0` path returns empty data without crashing (no msync dependency)

## 2. Implementation (TDD Green Phase)

- [ ] 2.1 Remove `msync` block in Parsers.swift (lines 91-98): delete the entire `#if canImport(Darwin)` ... `#endif` block
- [ ] 2.2 Add bounds check in MSRPC.swift before name alignment padding: `guard offset + 2 <= data.count else { throw POSIXError(.EINVAL, userInfo: [:]) }` before `offset += 2` on line ~74
- [ ] 2.3 Add bounds check in MSRPC.swift before comment alignment padding: same pattern before `offset += 2` on line ~97
- [ ] 2.4 Fix MSRPC.swift padding in `NetShareEnumAllRequest` (line 222): replace `serverNameLen % 2 == 1` with proper 4-byte NDR alignment based on `serverNameData.count`
- [ ] 2.5 Fix `pipelinedRead` in FileHandle.swift: collect window results into a temporary array, only append to `result` after all chunks in the window succeed. On error, throw without appending or advancing offset.
- [ ] 2.6 Fix `pipelinedWrite` in FileHandle.swift: on chunk error, throw immediately without advancing `currentOffset` or `dataOffset`. Add doc comment that partial writes leave file indeterminate.

## 3. Verification

- [ ] 3.1 Run all new tests — green
- [ ] 3.2 Run full test suite (`swift test`) — all pass
- [ ] 3.3 Run integration tests if Docker available — share enumeration and file read/write still work
