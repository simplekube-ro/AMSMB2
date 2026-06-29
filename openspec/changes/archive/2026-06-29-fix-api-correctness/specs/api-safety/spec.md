## Capability: api-safety

Force-unwraps replaced with safe alternatives; silent failures replaced with errors; sentinel values made consistent.

## Requirements

### R1: contents(atPath:range:) must throw when disconnected
- When `client` is nil, the returned `AsyncThrowingStream` must yield `POSIXError(.ENOTCONN)`
- Must NOT silently return an empty stream

### R2: setAttributes must use correct date key for attributeModificationDateKey
- The `.attributeModificationDateKey` case must read `attributes.attributeModificationDate` (not `contentModificationDate`)
- The ctime fields (`smb2_ctime`, `smb2_ctime_nsec`) must reflect the attribute modification date

### R3: smb2_readdir nil must not crash
- `Directory.subscript(index:)` must handle nil return from `smb2_readdir()` gracefully
- Return `smb2dirent()` (empty) on nil, consistent with the existing `?? smb2dirent()` fallback

### R4: ShareType must handle unknown values
- `ShareType` must have an `.unknown` case (or equivalent)
- `ShareProperties.type` must NOT force-unwrap the raw value initializer
- Unknown share type values from the server must produce `.unknown`, not crash

### R5: maxWriteSize must return 0 on error (not -1)
- Consistent with `maxReadSize` which returns `0`
- `optimizedWriteSize` and downstream callers must handle `0` correctly

### R6: server force-unwrap in shareEnumSwift must be safe
- Use `try server.unwrap()` or equivalent to produce a meaningful error on disconnected client

### R7: close() must not block indefinitely
- `SMB2FileHandle.close()` must use an async/fire-and-forget close pattern
- Must return promptly even if the server is unresponsive

### R8: url.host force-unwrap in connect() must be safe
- Guard `url.host` with an error throw (e.g., `POSIXError(.EINVAL)`) instead of force-unwrap

### R9: removeDirectory must handle directory symlinks
- Recursive delete must check `isLink` before `isDirectory`
- Symlinks (even to directories) must use `unlink`, not `rmdir`

## Verification

- Unit test: create SMB2Manager with nil client, call `contents(atPath:)`, consume stream, verify `.ENOTCONN` error
- Unit test: `ShareType(rawValue: 0xFF)` produces `.unknown` (not crash)
- Unit test: `maxWriteSize` returns `0` (not `-1`) when context unavailable
- Unit test: `Directory.subscript` returns empty `smb2dirent` when readdir would return nil
- Integration test: `setAttributes` with `.attributeModificationDateKey` correctly sets ctime
- Integration test: recursive delete of directory containing symlinks completes without error
