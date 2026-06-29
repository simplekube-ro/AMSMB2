## ADDED Requirements

### Requirement: Context field is private
The `SMB2Client.context` field SHALL be `private`, ensuring all access to the underlying `smb2_context` pointer goes through the `withThreadSafeContext` method which holds `_context_lock`.

#### Scenario: Direct context access produces compile error
- **WHEN** code outside `SMB2Client` attempts to read `client.context`
- **THEN** the compiler SHALL emit an access control error

#### Scenario: Internal call sites use withThreadSafeContext
- **WHEN** `SMB2FileHandle.init(fileDescriptor:on:)` needs to call `smb2_fh_from_file_id`
- **THEN** it SHALL call `client.withThreadSafeContext` to obtain the context pointer under the lock

#### Scenario: lseek uses withThreadSafeContext
- **WHEN** `SMB2FileHandle.lseek(offset:whence:)` needs to call `smb2_lseek`
- **THEN** it SHALL call `client.withThreadSafeContext` to obtain the context pointer under the lock

### Requirement: SMB2Client initializer is explicitly internal
The `SMB2Client.init(timeout:)` initializer SHALL be marked `internal` explicitly to prevent accidental promotion to `public`.

#### Scenario: External module cannot construct SMB2Client
- **WHEN** code in an external module attempts `SMB2Client(timeout: 30)`
- **THEN** the compiler SHALL emit an access control error

### Requirement: smb2fh typealias is internal
The `smb2fh` typealias SHALL be `internal` (not `public`), as no public API requires it.

#### Scenario: External module cannot reference smb2fh type
- **WHEN** code in an external module references the `smb2fh` type
- **THEN** the compiler SHALL emit an "undeclared type" error
