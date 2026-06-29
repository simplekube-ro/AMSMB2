# api-safety Specification

## Purpose
Eliminate API-correctness hazards on the public surface: replace force-unwraps with safe alternatives, turn silent failures into thrown errors, and make sentinel values consistent so callers get predictable, non-crashing behavior.

## Requirements

### Requirement: contents(atPath:range:) throws when disconnected
The `contents(atPath:range:)` API SHALL surface a disconnected client as an error rather than silently returning no data.

#### Scenario: Nil client yields ENOTCONN
- **WHEN** `client` is nil and a caller consumes the returned `AsyncThrowingStream`
- **THEN** the stream SHALL yield `POSIXError(.ENOTCONN)` and SHALL NOT silently return an empty stream

### Requirement: setAttributes uses the correct date key for attributeModificationDate
`setAttributes` SHALL map `.attributeModificationDateKey` to the attribute modification date, not the content modification date.

#### Scenario: attributeModificationDateKey sets ctime
- **WHEN** `setAttributes` handles the `.attributeModificationDateKey` case
- **THEN** it SHALL read `attributes.attributeModificationDate` (not `contentModificationDate`), and the `smb2_ctime` / `smb2_ctime_nsec` fields SHALL reflect the attribute modification date

### Requirement: smb2_readdir nil must not crash
`Directory.subscript(index:)` SHALL handle a nil return from `smb2_readdir()` without crashing.

#### Scenario: Nil readdir returns empty entry
- **WHEN** `smb2_readdir()` returns nil for a given index
- **THEN** `Directory.subscript(index:)` SHALL return an empty `smb2dirent()`, consistent with the existing `?? smb2dirent()` fallback

### Requirement: ShareType handles unknown values
`ShareType` SHALL represent unrecognized server values without force-unwrapping.

#### Scenario: Unknown raw value maps to .unknown
- **WHEN** the server returns a share type raw value with no defined case (e.g. `0xFF`)
- **THEN** `ShareType` SHALL produce `.unknown` (or equivalent) and `ShareProperties.type` SHALL NOT force-unwrap the raw-value initializer

### Requirement: maxWriteSize returns 0 on error
`maxWriteSize` SHALL use `0` as its error sentinel, consistent with `maxReadSize`.

#### Scenario: Unavailable context returns 0
- **WHEN** the context is unavailable
- **THEN** `maxWriteSize` SHALL return `0` (not `-1`), and `optimizedWriteSize` and downstream callers SHALL handle `0` correctly

### Requirement: shareEnumSwift server access is safe
`shareEnumSwift` SHALL NOT force-unwrap the server reference.

#### Scenario: Disconnected client produces a meaningful error
- **WHEN** the client/server is unavailable during `shareEnumSwift`
- **THEN** the code SHALL use `try server.unwrap()` (or equivalent) to produce a meaningful error instead of force-unwrapping

### Requirement: close() does not block indefinitely
`SMB2FileHandle.close()` SHALL return promptly even when the server is unresponsive.

#### Scenario: Unresponsive server does not hang close
- **WHEN** `SMB2FileHandle.close()` is called and the server is unresponsive
- **THEN** `close()` SHALL use an async/fire-and-forget close pattern and SHALL return promptly

### Requirement: connect() validates url.host safely
`connect()` SHALL NOT force-unwrap `url.host`.

#### Scenario: Missing host throws EINVAL
- **WHEN** `url.host` is nil during `connect()`
- **THEN** `connect()` SHALL throw an error (e.g. `POSIXError(.EINVAL)`) instead of force-unwrapping

### Requirement: removeDirectory handles directory symlinks
Recursive delete SHALL treat symlinks as links regardless of their target type.

#### Scenario: Symlink to directory is unlinked
- **WHEN** recursive delete encounters a symlink (including a symlink to a directory)
- **THEN** it SHALL check `isLink` before `isDirectory` and SHALL use `unlink`, not `rmdir`
