## 1. Tests First (TDD Red Phase)

- [ ] 1.1 Add test `testContentsAtPathThrowsWhenDisconnected`: create SMB2Manager (not connected), call `contents(atPath:)`, iterate stream, assert throws `POSIXError` with code `.ENOTCONN`
- [ ] 1.2 Add test `testShareTypeUnknownValue`: assert `ShareProperties(rawValue: 0xFFFF_FFFF).type` does not crash and returns `.unknown`
- [ ] 1.3 Add test `testShareTypeKnownValues`: assert all 4 known share types (0-3) still decode correctly
- [ ] 1.4 Add test `testMaxWriteSizeReturnsZeroWhenUnavailable`: create SMB2FileHandle mock/disconnected scenario, verify `maxWriteSize` returns `0`
- [ ] 1.5 Add test `testURLHostGuard`: attempt to create connection with a URL that has nil host, verify error thrown (not crash)

## 2. Implementation (TDD Green Phase)

- [ ] 2.1 Fix `contents(atPath:range:)` in AMSMB2.swift: change `guard let client = client else { return }` to `guard let client = client else { continuation.finish(throwing: POSIXError(.ENOTCONN)); return }`
- [ ] 2.2 Fix `setAttributes` in AMSMB2.swift: change `.attributeModificationDateKey` case to read `attributes.attributeModificationDate` instead of `attributes.contentModificationDate`
- [ ] 2.3 Fix `Directory.subscript` in Directory.swift: change `smb2_readdir(context, self.handle).pointee` to `smb2_readdir(context, self.handle)?.pointee ?? smb2dirent()`
- [ ] 2.4 Fix `ShareType` in Context.swift: add `case unknown = 0xFFFF_FFFF` and change force-unwrap to `ShareType(rawValue: rawValue & 0x0fff_ffff) ?? .unknown`
- [ ] 2.5 Fix `maxWriteSize` in FileHandle.swift: change `?? -1` to `?? 0`
- [ ] 2.6 Fix `shareEnumSwift` in Context.swift: change `server!` to `try server.unwrap()`
- [ ] 2.7 Fix `close()` in FileHandle.swift: replace synchronous `smb2_close(context, captured)` with `smb2_close_async(context, captured, SMB2Client.generic_handler_noop, nil)` (fire-and-forget pattern)
- [ ] 2.8 Fix `connect()` in AMSMB2.swift: change `url.host!` to `guard let host = url.host else { throw POSIXError(.EINVAL) }` and use `host`
- [ ] 2.9 Fix `removeDirectory` in AMSMB2.swift: in the recursive loop, check `item.isLink` first — if true, use `unlink`; else if `isDirectory`, use `rmdir`; else use `unlink`

## 3. Verification

- [ ] 3.1 Run all new tests — green
- [ ] 3.2 Run full test suite (`swift test`) — all pass
- [ ] 3.3 Run integration tests if Docker available — all pass
