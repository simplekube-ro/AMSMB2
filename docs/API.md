# AMSMB2 API Reference

Complete reference for the AMSMB2 public API. All async methods also have completion handler variants (see `ObjCCompat.swift`).

## Types Overview

| Type | Description |
|------|-------------|
| [`SMB2Manager`](#smb2manager) | Primary API class — connection lifecycle and all file/directory operations |
| [`SMB2Client`](#smb2client) | Low-level SMB2 context wrapper with thread-safe access |
| [`SMB2FileHandle`](#smb2filehandle) | File handle for direct read/write/seek operations |
| [`AsyncInputStream`](#asyncinputstream) | Adapts `AsyncSequence` to `InputStream` for streaming writes |
| [`SMB2FileChangeType`](#smb2filechangetype) | OptionSet for Change Notify filter flags |
| [`SMB2FileChangeAction`](#smb2filechangeaction) | Action type in a change notification (added, removed, modified, renamed) |
| [`SMB2FileChangeInfo`](#smb2filechangeinfo) | Single change notification entry (action + file name) |

---

## SMB2Manager

```swift
public class SMB2Manager: NSObject, NSSecureCoding, Codable, NSCopying,
                           CustomReflectable, @unchecked Sendable
```

The primary interface for SMB2/3 operations. Thread-safe. Supports serialization via `NSSecureCoding` and `Codable`.

> **Breaking Change:** Passwords are intentionally excluded from all serialization paths (`Codable` and `NSSecureCoding`) for security. When decoding a previously archived `SMB2Manager`, the password field will be empty. Legacy archives that contain a password field still decode without error — the password is simply ignored. Consumers that persist `SMB2Manager` must store credentials separately (e.g., Keychain) and re-supply them after decoding.

### Type Aliases

```swift
public typealias SimpleCompletionHandler = (@Sendable (_ error: (any Error)?) -> Void)?
public typealias ReadProgressHandler = (@Sendable (_ bytes: Int64, _ total: Int64) -> Bool)?
public typealias WriteProgressHandler = (@Sendable (_ bytes: Int64) -> Bool)?
```

Progress handlers return `true` to continue or `false` to cancel the operation.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `url` | `URL` | SMB server URL (read-only, set at init) |
| `timeout` | `TimeInterval` | Operation timeout in seconds (default: 60). Set to 0 to disable. |
| `smbClient` | `SMB2Client` (throws) | The underlying client. Throws `POSIXError(.ENOTCONN)` if not connected. |

---

### Connection Management

#### `init?(url:domain:credential:)`

```swift
public init?(url: URL, domain: String = "", credential: URLCredential?)
```

Creates an SMB2 manager for the given server URL. Returns `nil` if the URL scheme is not `smb` or has no host.

- **Parameters:**
  - `url` — SMB server URL (e.g., `smb://192.168.1.1`)
  - `domain` — User's domain for NTLM authentication (default: `""`)
  - `credential` — Username and password. Pass `nil` for guest access. The password is held in memory for the connection lifecycle but is excluded from serialization (`Codable`/`NSSecureCoding`) for security.

#### `connectShare(name:encrypted:)`

```swift
open func connectShare(name: String, encrypted: Bool = false) async throws
```

Connects to a named share on the server. Must be called before any file operations. Can be called multiple times — reconnects if already connected.

- **Parameters:**
  - `name` — Share name (e.g., `"Documents"`)
  - `encrypted` — Enable SMB3 encryption (default: `false`)
- **Throws:** `POSIXError` on connection failure (auth error, share not found, network error)

#### `disconnectShare(gracefully:)`

```swift
open func disconnectShare(gracefully: Bool = false) async throws
```

Disconnects from the current share.

- **Parameters:**
  - `gracefully` — If `true`, waits for in-flight operations to complete before disconnecting (default: `false`)

#### `echo()`

```swift
open func echo() async throws
```

Sends an SMB2 echo request. Use as a connection liveness check.

- **Throws:** Error if the connection is not active.

---

### Share Enumeration

#### `listShares(enumerateHidden:)`

```swift
open func listShares(enumerateHidden: Bool = false) async throws
    -> [(name: String, comment: String)]
```

Lists available shares on the server using MS-RPC (NetrShareEnum). Does not require a share connection.

- **Parameters:**
  - `enumerateHidden` — Include hidden shares (default: `false`)
- **Returns:** Array of tuples with share name and comment.

---

### Directory Operations

#### `contentsOfDirectory(atPath:recursive:)`

```swift
open func contentsOfDirectory(atPath path: String, recursive: Bool = false) async throws
    -> [[URLResourceKey: any Sendable]]
```

Lists the contents of a directory.

- **Parameters:**
  - `path` — Directory path (use `"/"` for share root)
  - `recursive` — List subdirectories recursively (default: `false`)
- **Returns:** Array of dictionaries. Each entry contains keys like `.nameKey`, `.pathKey`, `.fileSizeKey`, `.fileResourceTypeKey`, `.contentModificationDateKey`, `.creationDateKey`.

#### `createDirectory(atPath:)`

```swift
open func createDirectory(atPath path: String) async throws
```

Creates a directory at the specified path. Parent directories must already exist.

#### `removeDirectory(atPath:recursive:)`

```swift
open func removeDirectory(atPath path: String, recursive: Bool) async throws
```

Removes a directory. If `recursive` is `true`, removes all contents first.

---

### File Operations

#### `contents(atPath:range:progress:)`

```swift
open func contents<R: RangeExpression>(
    atPath path: String, range: R? = nil, progress: ReadProgressHandler
) async throws -> Data where R.Bound == UInt64
```

Reads file contents into memory.

- **Parameters:**
  - `path` — File path
  - `range` — Optional byte range to read (e.g., `..<1024` for first 1KB)
  - `progress` — Progress callback. Return `false` to cancel.
- **Returns:** File data.

#### `contents(atPath:range:)` (streaming)

```swift
@available(swift 5.9)
open func contents<R: RangeExpression>(
    atPath path: String, range: R? = Range<UInt64>?.none
) -> AsyncThrowingStream<Data, any Error> where R.Bound: FixedWidthInteger
```

Returns an `AsyncThrowingStream` that yields file data in chunks. Useful for processing large files without loading everything into memory.

- **Parameters:**
  - `path` — File path
  - `range` — Optional byte range to read (default: entire file)
- **Returns:** An `AsyncThrowingStream<Data, any Error>`. Yields `POSIXError(.ENOTCONN)` if not connected.

#### `contents(atPath:range:progress:)` (chunked)

```swift
open func contents(
    atPath path: String,
    progress: @Sendable @escaping (_ offset: Int64, _ total: Int64, _ chunk: Data) -> Bool,
    completionHandler: SimpleCompletionHandler
)
```

Reads file contents in chunks via callback. Useful for large files to avoid loading everything into memory.

- **Parameters:**
  - `progress` — Called with each chunk. `offset` is the position, `total` is file size, `chunk` is the data. Return `false` to cancel.

#### `write(data:toPath:progress:)`

```swift
open func write<DataType: DataProtocol>(
    data: DataType, toPath path: String, progress: WriteProgressHandler
) async throws
```

Creates or overwrites a file with the given data.

- **Parameters:**
  - `data` — Data to write (`Data`, `[UInt8]`, etc.)
  - `path` — Destination file path
  - `progress` — Progress callback. Return `false` to cancel.

#### `append(data:toPath:offset:progress:)`

```swift
open func append<DataType: DataProtocol>(
    data: DataType, toPath path: String, offset: Int64, progress: WriteProgressHandler
) async throws
```

Writes data at a specific offset. If the file is shorter than `offset`, it is extended. If longer, content after `offset` is truncated.

#### `write(stream:toPath:chunkSize:progress:)`

```swift
open func write<S>(
    stream: S, toPath path: String, chunkSize: Int = 0, progress: WriteProgressHandler
) async throws where S: AsyncSequence & Sendable, S.Element: DataProtocol
```

Writes data from an `AsyncSequence` stream to a file. Useful for streaming uploads without buffering the entire file.

#### `truncateFile(atPath:atOffset:)`

```swift
open func truncateFile(atPath path: String, atOffset: UInt64) async throws
```

Truncates or extends a file to the specified size.

#### `removeFile(atPath:)`

```swift
open func removeFile(atPath path: String) async throws
```

Removes a file.

#### `removeItem(atPath:)`

```swift
open func removeItem(atPath path: String) async throws
```

Removes a file or directory (with contents). Automatically detects the item type.

---

### File Attributes

#### `attributesOfFileSystem(forPath:)`

```swift
open func attributesOfFileSystem(forPath path: String) async throws -> [FileAttributeKey: Any]
```

Returns file system attributes. Keys include `.systemSize`, `.systemFreeSize`.

#### `attributesOfItem(atPath:)`

```swift
open func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: any Sendable]
```

Returns file or directory attributes. Keys include `.nameKey`, `.fileSizeKey`, `.fileResourceTypeKey`, `.contentModificationDateKey`, `.creationDateKey`, `.isDirectoryKey`.

Convenience accessors on the returned dictionary:

| Accessor | Type | Description |
|----------|------|-------------|
| `.name` | `String?` | File name |
| `.path` | `String?` | Full path |
| `.fileResourceType` | `URLFileResourceType?` | `.regular`, `.directory`, `.symbolicLink` |
| `.isDirectory` | `Bool` | True if directory |
| `.isRegularFile` | `Bool` | True if regular file |
| `.isSymbolicLink` | `Bool` | True if symlink |
| `.fileSize` | `Int64?` | File size in bytes |
| `.contentModificationDate` | `Date?` | Last modified date |
| `.creationDate` | `Date?` | Creation date |
| `.contentAccessDate` | `Date?` | Last access date |
| `.attributeModificationDate` | `Date?` | Attribute change date |

#### `setAttributes(attributes:ofItemAtPath:)`

```swift
open func setAttributes(attributes: [URLResourceKey: Any], ofItemAtPath path: String) async throws
```

Sets file attributes. Supported keys: `.creationDateKey`, `.contentModificationDateKey`, `.contentAccessDateKey`, `.attributeModificationDateKey`, `.isHiddenKey`.

---

### Symbolic Links

#### `createSymbolicLink(atPath:withDestinationPath:)` (internal)

```swift
func createSymbolicLink(atPath path: String, withDestinationPath destination: String) async throws
```

Creates a symlink at `path` pointing to `destination`. Uses SMB2 reparse points. Requires server support (Samba 4.21+).

#### `destinationOfSymbolicLink(atPath:)`

```swift
open func destinationOfSymbolicLink(atPath path: String) async throws -> String
```

Returns the target path of a symlink.

---

### Copy and Move

#### `copyItem(atPath:toPath:recursive:progress:)`

```swift
open func copyItem(
    atPath path: String, toPath: String, recursive: Bool,
    progress: ReadProgressHandler
) async throws
```

Copies a file or directory using server-side copy (FSCTL_SRV_COPYCHUNK). Much faster than download+upload since data stays on the server. Chunks are capped at 1 MiB per MS-SMB2 spec.

#### `moveItem(atPath:toPath:)`

```swift
open func moveItem(atPath path: String, toPath: String) async throws
```

Renames/moves a file or directory. Source and destination must be on the same share.

---

### Upload and Download

#### `uploadItem(at:toPath:progress:)`

```swift
open func uploadItem(
    at url: URL, toPath path: String, progress: WriteProgressHandler
) async throws
```

Uploads a local file to the SMB share. The `url` must be a local file URL. Fails with `EEXIST` if the destination already exists.

#### `downloadItem(atPath:to:progress:)`

```swift
open func downloadItem(
    atPath path: String, to url: URL, progress: ReadProgressHandler
) async throws
```

Downloads a file from the SMB share to a local URL.

---

### File Monitoring

#### `monitorItem(atPath:for:)` (internal)

```swift
func monitorItem(atPath path: String, for filter: SMB2FileChangeType) async throws
    -> [SMB2FileChangeInfo]
```

Monitors a file or directory for changes. Blocks until a change matching the filter occurs or timeout expires. The operation uses the event loop like any other async operation, so it does not block other operations on the same connection. However, using a separate connection for monitoring is still recommended for clarity.

- **Parameters:**
  - `path` — Path to monitor
  - `filter` — Change types to watch for (e.g., `[.fileName, .recursive]`)
- **Returns:** Array of change notifications.

---

## SMB2Client

```swift
public final class SMB2Client: CustomDebugStringConvertible, CustomReflectable,
                                @unchecked Sendable
```

Low-level wrapper around libsmb2's `smb2_context`. All access to the underlying C context is serialized through a dedicated serial `DispatchQueue` (the "event loop"). Socket I/O is driven by `DispatchSource` for efficient, non-blocking operation handling. Multiple operations can be in-flight simultaneously.

| Property | Type | Description |
|----------|------|-------------|
| `timeout` | `TimeInterval` | Operation timeout |
| `debugDescription` | `String` | Debug info |
| `customMirror` | `Mirror` | Mirror with server, security mode, auth, user, version, connection state |

Typically accessed via `SMB2Manager.smbClient` (throws if not connected).

---

## SMB2FileHandle

```swift
public final class SMB2FileHandle: @unchecked Sendable
```

Represents an open file on the SMB share. Obtained by opening files through `SMB2Client`.

| Member | Type | Description |
|--------|------|-------------|
| `maxReadSize` | `Int` | Maximum read size negotiated with server |
| `close()` | Method | Closes the handle. Safe to call from any thread. Uses lock-nil-swap pattern to prevent double-close. |
| `fstat()` | Method | Returns `smb2_stat_64` with file metadata. Throws on error. |
| `pread(offset:length:)` | Method | Reads data at offset without changing file position. |
| `pipelinedRead(offset:totalLength:chunkSize:maxInFlight:)` | Method | Reads `totalLength` bytes using multiple concurrent pread requests. Up to `maxInFlight` (default: 4) chunks are dispatched simultaneously via `DispatchGroup`. Results are returned in offset order. |
| `pipelinedWrite(data:offset:chunkSize:maxInFlight:)` | Method | Writes data using multiple concurrent pwrite requests. Up to `maxInFlight` (default: 4) chunks are dispatched simultaneously. Returns total bytes written. |

---

## SMB2FileChangeType

```swift
public struct SMB2FileChangeType: OptionSet, Hashable, Sendable, CustomStringConvertible
```

Bit flags for Change Notify filters.

| Flag | Description |
|------|-------------|
| `.fileName` | File name changes |
| `.directoryName` | Directory name changes |
| `.attributes` | Attribute changes |
| `.size` | Size changes |
| `.write` | Last write time changes |
| `.access` | Last access time changes |
| `.create` | Creation time changes |
| `.extendedAttributes` | Extended attribute changes |
| `.security` | ACL changes |
| `.streamName` | Named stream additions |
| `.streamSize` | Named stream size changes |
| `.streamWrite` | Named stream modifications |
| `.recursive` | Watch subdirectories recursively |
| `.contentModify` | Compound: `.create` + `.write` + `.size` |
| `.all` | All change types (excluding recursive) |

## SMB2FileChangeAction

```swift
public struct SMB2FileChangeAction: RawRepresentable, Hashable, Sendable, CustomStringConvertible
```

| Value | Description |
|-------|-------------|
| `.added` | File/directory was added |
| `.removed` | File/directory was removed |
| `.modified` | File/directory was modified |
| `.renamedOldName` | Renamed — this entry has the old name |
| `.renamedNewName` | Renamed — this entry has the new name |
| `.addedStream` | Named stream was added |
| `.removedStream` | Named stream was removed |
| `.modifiedStream` | Named stream was modified |

## SMB2FileChangeInfo

```swift
public struct SMB2FileChangeInfo: Hashable, Sendable
```

| Property | Type | Description |
|----------|------|-------------|
| `action` | `SMB2FileChangeAction` | The type of change |
| `fileName` | `String?` | Name of the changed file |

---

## AsyncInputStream

```swift
public class AsyncInputStream<Seq>: InputStream, @unchecked Sendable
    where Seq: AsyncSequence, Seq.Element: DataProtocol
```

Adapts an `AsyncSequence` of `DataProtocol` chunks into an `InputStream` for use with `SMB2Manager.write(stream:toPath:)`.

### Backpressure

`AsyncInputStream` uses high-water/low-water mark flow control to bound memory usage during large file streaming:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `highWaterMark` | 4 MB (4,194,304 bytes) | When the internal buffer exceeds this size, the prefetch task suspends. |
| `lowWaterMark` | 1 MB (1,048,576 bytes) | When consumption drains the buffer below this size, the suspended prefetch task resumes. |

This prevents unbounded memory growth when the producer (async sequence) is faster than the consumer (SMB write operations). The prefetch task also resumes if the stream is closed, to avoid deadlocks.

---

## Common Errors

All operations throw `POSIXError` on failure. Common codes:

| Code | Constant | Meaning |
|------|----------|---------|
| 1 | `EPERM` | Operation not permitted |
| 2 | `ENOENT` | File or directory not found |
| 5 | `EIO` | I/O error (network or protocol) |
| 13 | `EACCES` | Permission denied |
| 17 | `EEXIST` | File already exists (e.g., `uploadItem` to existing path) |
| 57 | `ENOTCONN` | Not connected (call `connectShare` first) |
| 60 | `ETIMEDOUT` | Operation timed out |
