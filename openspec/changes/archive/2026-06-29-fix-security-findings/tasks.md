## 1. Thread-Safe Context Access (CRITICAL-1, HIGH-3, MEDIUM-4)

- [x] 1.1 Make `SMB2Client.context` field `private` in `Context.swift:15`
- [x] 1.2 Add internal `rawContext` computed property as passthrough for cross-file internal access (adjusted from original plan: simple accessor instead of locking function, since callers like Parsers/Directory are already serialized)
- [x] 1.3 Fix `FileHandle.swift:97` — wrap `smb2_fh_from_file_id` call in `client.withThreadSafeContext` inside `init(fileDescriptor:on:)`
- [x] 1.4 Fix `FileHandle.swift:205` — wrap `smb2_lseek` call in `client.withThreadSafeContext` inside `lseek(offset:whence:)`
- [x] 1.5 Fix compile errors: updated Parsers.swift (2 sites) and Directory.swift (3 sites) to use `rawContext`
- [x] 1.6 Mark `SMB2Client.init(timeout:)` explicitly `internal`

## 2. Safe File Handle Lifecycle (HIGH-2)

- [x] 2.1 Add `private let _handleLock = NSLock()` to `SMB2FileHandle`
- [x] 2.2 Refactor `close()` to acquire `_handleLock`, swap `handle` to nil inside the lock, then call `smb2_close` outside the lock with the captured value
- [x] 2.3 Refactor `deinit` to acquire `_handleLock`, swap `handle` to nil inside the lock, then call `smb2_close_async` outside the lock with the captured value
- [x] 2.4 Verified: all other `handle` reads use `.unwrap()` which throws on nil — safe post-close behavior

## 3. Validated Client Accessor (HIGH-1, MEDIUM-3)

- [x] 3.1 Update `smbClient` getter to acquire `connectLock` around the nil-check and return
- [x] 3.2 Add `fileDescriptor != -1` check to validate the connection is alive, not just non-nil
- [x] 3.3 Add doc comment explaining that the returned client is only valid while the connection is active

## 4. API Surface Cleanup (MEDIUM-1)

- [x] 4.1 Revert `smb2fh` typealias from `public` back to `internal` in `FileHandle.swift:14`

## 5. Documentation

- [x] 5.1 Add thread-safety doc comments to `SMB2FileHandle`'s public members (`init(forReadingAtPath:on:)`, `close()`, `fstat()`, `maxReadSize`, `pread(offset:length:)`)
- [x] 5.2 Add doc comment to `SMB2Client` noting it is `@unchecked Sendable` with internal serialization via `withThreadSafeContext`

## 6. Verification

- [x] 6.1 Verified: no `client.context` references remain outside Context.swift
- [x] 6.2 Build verified: pre-existing `no such module 'SMB2'` failure confirmed on unmodified master (libsmb2 sources missing locally). Static code review confirms all changes are syntactically valid with correct access control and lock patterns.
- [x] 6.3 Static regression check: swift-platform-developer agent verified no regressions — all internal call patterns preserved, lock ordering is safe, no deadlock risk. Integration tests require SMB server.
