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
| [`SMBTransport`](#smbtransport) | Public protocol — the transport seam carrying SMB2 bytes over the wire (Apple) |
| [`SMBTransportKind`](#smbtransportkind) | Enum selecting a transport: `.tcp` / `.quic` / `.automatic` |
| [`TCPTransportApple`](#tcptransportapple) | Concrete `SMBTransport` over `NIOTransportServices` (Apple only) |
| [`QUICTransportApple`](#quictransportapple) | Concrete `SMBTransport` over Network.framework QUIC (Apple only, availability-gated) |
| [`SMBQUICConfiguration`](#smbquicconfiguration) | Platform-neutral SMB-over-QUIC config: TLS `TrustPolicy` + connect timeout |
| [`SMBQUICCertificateProbe`](#smbquiccertificateprobe) | Capture-only SMB-over-QUIC TLS handshake returning the server's DER certificate chain, leaf first — for trust-on-first-use (Swift-only; Apple, availability-gated; Linux throws `ENOTSUP`) |

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
| `transportKind` | `SMBTransportKind` | Transport for the next connection (default `.automatic` → TCP). Set before `connectShare`. Swift-only; see [SMB-over-QUIC](#smb-over-quic). |
| `quicConfiguration` | `SMBQUICConfiguration?` | Optional QUIC trust policy + connect timeout, used only when `transportKind == .quic` (`nil` = all defaults). Swift-only. |

Both settings are **set-before-connect** and snapshotted under the manager's lock at the start of each connect — mutating them never affects an in-flight or established connection; new values apply to the next `connectShare` (exactly like `timeout`). They are platform-neutral (present on Linux too) but **Swift-only** — intentionally absent from the Objective-C interface (see [SMB-over-QUIC](#smb-over-quic)).

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
- **Transport note:** On Apple platforms this connects through the [`SMBTransport`](#smbtransport) seam (NIO/Network.framework `TCPTransportApple`, selected as `.automatic`); on Linux it uses libsmb2's built-in socket. The transport is not currently selectable through the public API. See [ARCHITECTURE.md → Transport Layer](ARCHITECTURE.md#transport-layer).

#### `disconnectShare(gracefully:)`

```swift
open func disconnectShare(gracefully: Bool = false) async throws
```

Disconnects from the current share.

- **Parameters:**
  - `gracefully` — If `true`, waits for in-flight operations to complete before disconnecting (default: `false`)
- **Lifetime note:** disconnecting does not destroy the underlying context; its resources are reclaimed when the `SMB2Manager` is released. For long-lived connection pools, prefer constructing a fresh manager over reusing a disconnected one. See [Client lifetime, cancellation, and pooling](ARCHITECTURE.md#client-lifetime-cancellation-and-pooling-consumer-guidance) and [#49](https://github.com/simplekube-ro/AMSMB2/issues/49).

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

#### `contentsOfDirectory(atPath:recursive:)` (lazy streaming)

```swift
@available(swift 5.9)
open func contentsOfDirectory(
    atPath path: String, recursive: Bool = false
) -> AsyncThrowingStream<[URLResourceKey: any Sendable], any Error>
```

Lazy variant that yields one entry at a time. Useful for large directories where loading the full listing into memory is undesirable.

- **Parameters:**
  - `path` — Directory path (use `"/"` for share root)
  - `recursive` — List subdirectories recursively (default: `false`)
- **Returns:** An `AsyncThrowingStream` that yields one attribute dictionary per entry. Throws `POSIXError(.ENOTCONN)` if not connected.

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
| `debugDescription` | `String` | Human-readable debug string; safe on unconnected clients |
| `customMirror` | `Mirror` | Mirror with server, security mode, auth, user, version, connection state; nil-safe on unconnected clients |

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
| `pipelinedRead(offset:totalLength:chunkSize:maxInFlight:)` | Method | Reads `totalLength` bytes using multiple concurrent pread requests. Up to `maxInFlight` (default: 4) chunks are dispatched simultaneously via structured concurrency (withThrowingTaskGroup). Results are returned in offset order. |
| `pipelinedWrite(data:offset:chunkSize:maxInFlight:)` | Method | Writes data using multiple concurrent pwrite requests. Up to `maxInFlight` (default: 4) chunks are dispatched simultaneously. Returns total bytes written. |

### Factory Methods

All factory methods are `async throws` and must be called after `connectShare`.

```swift
static func open(forReadingAtPath path: String, on client: SMB2Client) async throws -> SMB2FileHandle
static func open(forWritingAtPath path: String, on client: SMB2Client) async throws -> SMB2FileHandle
static func open(forUpdatingAtPath path: String, on client: SMB2Client) async throws -> SMB2FileHandle
static func open(forOverwritingAtPath path: String, on client: SMB2Client) async throws -> SMB2FileHandle
static func open(forCreatingAndWritingAtPath path: String, on client: SMB2Client) async throws -> SMB2FileHandle
```

These mirror the `SMB2FileHandle.OpenMode` enum values and are the preferred way to obtain a file handle via direct `SMB2Client` access (advanced use case). Always call `close()` when finished — the handle does not close itself automatically on `deinit`.

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

## SMBTransport

```swift
public typealias InboundReceiver = @Sendable (Result<Data, POSIXError>) -> Void

public protocol SMBTransport: Sendable {
    func connect(host: String, port: Int, onReceive: @escaping InboundReceiver) async throws
    func send(_ bytes: Data) async throws
    func close() async
}
```

The transport seam: the abstraction that carries raw SMB2 bytes over the network, decoupled from any specific wire implementation. It is intentionally free of SwiftNIO and libsmb2 dependencies, so conformers can be unit-tested in isolation and reused by both the TCP and QUIC transports.

- **Buffer type:** `Foundation.Data` (concrete transports convert to/from NIO `ByteBuffer` internally).
- **Inbound is push:** the receiver is a parameter of `connect`, so a connection cannot exist without one. There is no `receive()` and no separate registration step.
- **Delivery contract:** the transport invokes `onReceive` on its own serial delivery queue — once per inbound chunk in arrival order, once with empty `Data` for graceful EOF, or once with a `POSIXError` for abnormal connection loss. EOF and failure are terminal (nothing follows either), nothing is delivered once `close()` has begun, a `connect` that throws never invokes its handler, and a rejected repeat `connect` never replaces the live receiver. The handler runs on the network queue: it must return promptly and must not suspend.
- **Concurrency:** conformers must be `Sendable` (use an `actor`, or a `final class` with justified `@unchecked Sendable`).
- **Errors:** `connect(host:port:onReceive:)` throws `POSIXError` on failure (e.g. `.ECONNREFUSED`).

### Migrating a conformer from `receive()`

A pull-style conformer that buffered bytes for `receive()` becomes a forwarder: store the handler at connect, invoke it from the network callback, and stop at the first terminal delivery.

```swift
// Before — buffer + parked continuation, drained by the pull loop.
func connect(host: String, port: Int) async throws { /* … */ }
func receive() async throws -> Data { /* park until a chunk, EOF or an error */ }

// After — the callback is the delivery.
private var receiver: InboundReceiver?              // @Sendable (Result<Data, POSIXError>) -> Void
private var terminated = false                     // EOF/error/close are terminal

func connect(host: String, port: Int, onReceive: @escaping InboundReceiver) async throws {
    try reserveSingleAttempt()                     // throws → handler never installed
    lock.withLock { receiver = onReceive }         // installed only after the reservation
    try await establishConnection(host: host, port: port)
}

// On the network queue, for each event:
private func forward(_ result: Result<Data, POSIXError>, terminal: Bool) {
    let receiver = lock.withLock { () -> InboundReceiver? in
        guard !terminated, let receiver else { return nil }
        if terminal { terminated = true }
        return receiver
    }
    receiver?(result)                              // never invoked while holding the lock
}
// chunk    → forward(.success(bytes), terminal: false)   // skip zero-length reads
// peer EOF → forward(.success(Data()), terminal: true)
// error    → forward(.failure(mapped), terminal: true)
// close()  → set `terminated` and drop `receiver` before tearing the connection down
```

Empty `Data` still means graceful EOF, so a zero-length read must be skipped rather than forwarded; the buffer and the parked continuation are deleted along with `receive()`.

> On Apple platforms, `SMB2Manager.connectShare(...)` drives this seam automatically. The protocol is `public` for extensibility, but the public API does not yet expose injecting a custom transport. See [ARCHITECTURE.md → Transport Layer](ARCHITECTURE.md#transport-layer).

## SMBTransportKind

```swift
public enum SMBTransportKind: Sendable, Equatable, Hashable {
    case tcp
    case quic
    case automatic
}
```

Selects which transport a connection uses.

| Case | Meaning |
|------|---------|
| `.tcp` | Explicit TCP. On Apple routes through `NIOTransportServices`; on Linux falls back to libsmb2's built-in BSD socket. |
| `.quic` | SMB-over-QUIC (Apple, availability-gated — see [`QUICTransportApple`](#quictransportapple)). Explicit opt-in; non-numeric hostnames only; UDP/443 default; no silent TCP fallback. On Linux, or below the availability floor, selecting it throws `POSIXError(.ENOTSUP)`. See [SMB-over-QUIC](#smb-over-quic). |
| `.automatic` | Let the library choose the best available transport on the current platform. Currently TCP — `.automatic` never selects QUIC. This is what `SMB2Manager` uses by default. |

## TCPTransportApple

```swift
public final class TCPTransportApple: SMBTransport, @unchecked Sendable {
    public init(connectTimeoutSeconds: Int = 30)
}
```

Concrete `SMBTransport` backed by `NIOTransportServices` (SwiftNIO over Network.framework). **Apple only** (`#if canImport(Network)`); absent on Linux.

- One instance maps to one TCP connection lifetime — after `close()` the instance is unusable; create a fresh one to reconnect.
- Converts the seam's `Data` payloads to/from NIO `ByteBuffer` internally and buffers inbound bytes so the bridge's synchronous `recv` can drain incrementally.
- All NWError / ChannelError values are mapped to `POSIXError` before propagating, matching the library's error convention.
- **Parameters:**
  - `connectTimeoutSeconds` — maximum time (whole seconds) for the TCP handshake (default: 30, matching the libsmb2 default).

---

## QUICTransportApple

```swift
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
public final class QUICTransportApple: SMBTransport, @unchecked Sendable {
    public init(configuration: SMBQUICConfiguration) throws
}
```

Concrete `SMBTransport` backed directly by Network.framework `NWProtocolQUIC` (no NIO). **Apple only** (`#if canImport(Network)`) and **availability-gated** above the package floor — the `@available` annotation names **macCatalyst 15** explicitly. Below the floor (and on Linux) `.quic` fails with `POSIXError(.ENOTSUP)`; the package platform minimums are unchanged.

- One QUIC connection with a **single bidirectional stream** carries the whole SMB session; `send`/`receive` write/read that stream verbatim (SMB2 message multiplexing continues inside it, exactly as over TCP). ALPN is `"smb"`, SNI is the target host, TLS 1.3 is QUIC-implied.
- The connect deadline is **always armed** from `configuration.connectTimeout` (see [`SMBQUICConfiguration`](#smbquicconfiguration)), independent of `SMB2Manager.timeout`. The initializer validates and normalizes it — `POSIXError(.EINVAL)` for `NaN`/infinite/zero/negative values, clamped to 3600 s above that — so a constructed transport can never hold an invalid deadline.
- All `NWError` values are mapped to `POSIXError` before propagating.
- You normally never construct this directly — set `SMB2Manager.transportKind = .quic`; the manager builds it from your `quicConfiguration`.

---

## SMBQUICConfiguration

```swift
public struct SMBQUICConfiguration: Sendable, Equatable {
    public enum TrustPolicy: Sendable, Equatable {
        case system                     // default: system chain evaluation + hostname verification
        case customRoots([Data])        // DER anchors; non-empty; REPLACE system roots; hostname still verified
        case insecureNoVerification     // debug-only: disables chain + hostname checks
    }
    public var trustPolicy: TrustPolicy = .system
    public var connectTimeout: TimeInterval = 30
    public init(trustPolicy: TrustPolicy = .system, connectTimeout: TimeInterval = 30)
}
```

Platform-neutral SMB-over-QUIC configuration — it holds **no Security.framework types** (trust anchors are DER-encoded `[Data]`), so it compiles and is public API on every platform, including Linux (where it is inert because `.quic` throws `ENOTSUP`).

**`TrustPolicy`** (secure by default; the enum makes "custom roots + insecure" unrepresentable):

| Case | Behavior |
|------|----------|
| `.system` (default) | System trust store evaluates the chain; hostname verified. No custom verify logic installed. |
| `.customRoots([Data])` | DER anchors **replace** the system roots (not augment); a self-signed leaf may be its own anchor; hostname is still verified. Invalid DER or an empty `.customRoots([])` set throws `POSIXError(.EINVAL)` before any network activity. |
| `.insecureNoVerification` | **Debug-only escape hatch.** Disables certificate-chain validation and hostname verification. TLS 1.3 encryption and the ALPN `"smb"` requirement remain. Never bypasses numeric-host rejection. |

**`connectTimeout`** — the dedicated QUIC connect deadline in seconds (default **30**). Finite and positive only: `NaN`, `±infinity`, `0`, and negative values throw `POSIXError(.EINVAL)`; values above **3600** clamp to 3600. It is **independent of `SMB2Manager.timeout`** (whose "zero-or-negative disables" contract is unchanged and continues to feed the per-operation `smb2_set_timeout`); the QUIC connect deadline cannot be disabled.

> A verify-failed QUIC handshake (`.system` against an untrusted cert, or `.customRoots` with a non-matching anchor) **fails fast**, bounded by the handshake itself rather than by `connectTimeout`: it surfaces as `POSIXError(.EPROTO)` carrying the Security `OSStatus` under `userInfo[NSUnderlyingErrorKey]` (an `NSError` in `NSOSStatusErrorDomain`). `connectTimeout` therefore bounds an unreachable or unresponsive endpoint, which surfaces as `POSIXError(.ETIMEDOUT)` — a trust rejection and an unreachable server are distinguishable by error code alone, with no description-string parsing. The one exception is a `connectTimeout` shorter than the handshake itself: if the deadline expires before the TLS outcome is reported, the deadline wins and the caller sees `ETIMEDOUT` (its description names the last TLS status, but there is no `NSUnderlyingErrorKey`).

---

## SMBQUICCertificateProbe

```swift
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
public enum SMBQUICCertificateProbe {
    public static func fetchServerCertificateChain(
        server: String, timeout: TimeInterval = 8
    ) async throws -> [Data]
}
```

Caseless namespace enum. `fetchServerCertificateChain(server:timeout:)` performs exactly **one** SMB-over-QUIC TLS handshake (ALPN `"smb"`, SNI = host, TLS 1.3 — the same wire contract `.quic` connect uses) against `server` with a **capture-only** verify step and returns the DER-encoded certificate chain the server presented, **leaf first**, as `[Data]` (no Security.framework types on the surface). It exists so an app can implement trust-on-first-use (see [Trust on first use](#trust-on-first-use)) without re-implementing the handshake or sideloading a `.cer`. Declared on every platform, so consumers need no `#if`; **Swift-only** and absent from the Objective-C interface, like the rest of the QUIC surface.

**`server`** is a `host[:port]` string — the same form `SMB2Manager` accepts for `.quic`:

| Value | Handshake target |
|-------|------------------|
| `"fs.example.com"` | UDP/443 — the SMB-over-QUIC default port |
| `"fs.example.com:4433"` | UDP/4433 — an explicit port is honored |

**Capture-only contract:**

- The verify step captures the chain and then **always rejects** the handshake — no code path completes verification — so the connection is torn down before any application data flows. The server's own rejection after the capture is the expected outcome, not an error.
- The peer is **never trusted**, no SMB PDU is ever sent, and **no SMB session** (or `SMB2Client`) is created. The probe returns bytes; deciding to trust them is the app's job.
- **No connection outlives the call.** On every exit path — chain returned, `EPROTO`, `ETIMEDOUT`, `CancellationError`, and the defensive case of a server that unexpectedly accepts the handshake — a started connection is cancelled exactly once, and the probe does not return until that teardown has completed.
- The capture mode is internal and **unreachable from any public configuration** — `SMBQUICConfiguration` and its `TrustPolicy` cases are unchanged; you cannot *connect* with it.

**Validation** — the same classifier `.quic` connect uses, so the two surfaces cannot drift; every check runs before any network activity:

| Input | Rule |
|-------|------|
| host | Non-numeric names only (the QUIC connection policy). A numeric IPv4/IPv6 host in any form, or an empty host → `POSIXError(.EINVAL)`. |
| port | Optional; defaults to 443. An explicit port outside 1...65535 (`0`, `65536`, an oversized digit string) → `POSIXError(.EINVAL)`. |
| `timeout` | The QUIC connect-timeout rules: `NaN`, `±infinity`, `0`, and negative values → `POSIXError(.EINVAL)`; values above 3600 s clamp to 3600. Default **8 s**. |

**`timeout` is independent of `SMBQUICConfiguration.connectTimeout`** (default 30 s) and of `SMB2Manager.timeout`. The probe is interactive — a user is typically waiting on a "fetch certificate" button — and a TLS rejection arrives in about 0.2 s, so 8 s is generous for the path that succeeds, while a UDP black hole (a TCP-only host, a firewalled port) must not stall the UI for the 30 s a real session setup is allowed to take. Pass a different `timeout` if your UI needs another bound; it never affects `.quic` connect.

**Outcomes** (keyed on the thrown error, not on connection state — a captured chain wins over any error except cancellation):

| Outcome | Meaning |
|---------|---------|
| returns `[Data]` | The chain the server presented, leaf first (`chain[0]` is the server certificate). Also returned when the deadline expired *after* the chain was captured, and when the server unexpectedly accepted the handshake — the connection is torn down regardless. Never empty on success. |
| throws `POSIXError(.EPROTO)` | The TLS handshake was rejected **before any certificate was delivered** — an ALPN mismatch, a non-QUIC listener that still answers TLS, a server that accepted without ever presenting a chain. The Security `OSStatus` is available as `userInfo[NSUnderlyingErrorKey]` (an `NSError` in `NSOSStatusErrorDomain`). |
| throws `POSIXError(.ETIMEDOUT)` | The endpoint was unreachable or unresponsive within `timeout` and no certificate was captured — e.g. a TCP-only host on 445, or a UDP port with no QUIC listener. The probe never takes longer than `timeout` plus teardown to return; it never hangs. |
| throws `CancellationError` | The calling task was cancelled while the probe was waiting — **even if a chain had already been captured** (a cancelled task never observes a success value; re-probe). The connection is torn down before the error is thrown. |
| throws `POSIXError(.EINVAL)` | `server` or `timeout` failed the validation above; no connection attempt was started. |
| throws `POSIXError(.ENOTSUP)` | Linux (no Network.framework). Thrown before any validation, so on Linux a numeric host yields `ENOTSUP`, not `EINVAL` — the same ordering as `.quic` connect. Surfaces as the `EOPNOTSUPP` alias there. |
| compile-time unavailable | Below the Apple availability floor (iOS 15 / macOS 12 / macCatalyst 15 / tvOS 15 / watchOS 8 / visionOS 1) the symbol is `@available`-gated exactly like `QUICTransportApple` — it does not throw; guard the call with `if #available(...)`. |

> **What "the chain" is.** The array is the chain *as presented to Security.framework*, leaf first (`SecTrustCopyCertificateChain`). For self-signed and private-CA servers — the cases trust-on-first-use exists for — that is exactly what the server sent: a single self-signed leaf, or the leaf followed by the intermediates the server included. Against a publicly-trusted server, Security.framework may append a system root the server did not send; that is harmless for TOFU (such a server is what `.system` trust is for).

---

## SMB-over-QUIC

Opt into QUIC by setting `SMB2Manager.transportKind = .quic` (optionally with a `quicConfiguration`) before `connectShare`. Availability floor per platform: **iOS 15 / macOS 12 / macCatalyst 15 / tvOS 15 / watchOS 8 / visionOS 1**. On Linux the settings exist but are inert — `.quic` throws `POSIXError(.ENOTSUP)` (on Linux this surfaces as its `EOPNOTSUPP` alias; `.ENOTSUP` is not a distinct `POSIXErrorCode` there) before any transport is constructed or any packet is sent.

**Connection policy:**

- **Explicit opt-in** — `.automatic` never selects QUIC.
- **Non-numeric hostnames only** — every numeric IPv4/IPv6 target (in any form) is rejected with `POSIXError(.EINVAL)` before any transport exists. `localhost`, single-label names, and other non-numeric names are accepted even though they may later fail resolution. Rejection **precedes and is independent of** the TLS trust policy — `.insecureNoVerification` does not bypass it.
- **UDP/443 default** — an explicit port in the server string is honored; otherwise QUIC defaults to 443 (TCP defaults to 445).
- **No silent fallback** — a `.quic` connect failure is surfaced to you; the library never retries over TCP on its own.

**Connect error codes:** `EINVAL` (numeric target host, invalid DER anchor, empty `.customRoots([])`, invalid `connectTimeout`, explicit port outside 1...65535), `ENOTSUP` (below the availability floor, or Linux), `EPROTO` (TLS handshake/trust rejection — prompt, with the Security `OSStatus` under `NSUnderlyingErrorKey`), `ETIMEDOUT` (the `connectTimeout` deadline — an unreachable or unresponsive endpoint; a TLS rejection surfaces here only if the deadline expires before the handshake outcome is reported), `ECONNABORTED` (`close()` during connect), and `CancellationError` for task cancellation.

**Snapshot / copy / serialization semantics:**

- `transportKind` and `quicConfiguration` are snapshotted at connect start; changes never affect an in-flight or established connection (they apply to the next `connectShare`).
- `copy()` preserves both `transportKind` and `quicConfiguration`.
- `NSSecureCoding`/`Codable` round-trip **only** `transportKind` (via a private string mapping; old/unknown archives decode to `.automatic`). `quicConfiguration` is **never serialized** — trust anchors and the insecure flag are security-sensitive, so a decoded `.quic` manager gets `quicConfiguration == nil` (system-trust default). This copy-vs-archive asymmetry is deliberate.

**Objective-C:** `transportKind`, `quicConfiguration`, `SMBQUICConfiguration`, `QUICTransportApple`, and `SMBQUICCertificateProbe` are **Swift-only** — their types are not Objective-C-representable, so they are absent from the generated Objective-C interface (the existing Objective-C API is unchanged). An Objective-C app opts into QUIC through a small Swift shim, e.g.:

```swift
// AMSMB2QUICShim.swift — call from Objective-C
@objc extension SMB2Manager {
    @objc func useQUIC(insecure: Bool) {
        transportKind = .quic
        quicConfiguration = SMBQUICConfiguration(
            trustPolicy: insecure ? .insecureNoVerification : .system)
    }
}
```

**Best-effort disconnect:** local `disconnect()` queues and flushes the DISCONNECT PDU but does not guarantee wire delivery (the seam may tear down first). SMB sessions survive this — servers reap idle sessions.

**Caller-side fallback pattern** (the library does not fall back for you):

```swift
manager.transportKind = .quic
manager.quicConfiguration = SMBQUICConfiguration()   // system trust, 30 s connect timeout
do {
    try await manager.connectShare(name: "share")
} catch {
    manager.transportKind = .automatic               // retry over TCP
    try await manager.connectShare(name: "share")
}
```

### Trust on first use

For a self-signed or private-CA server, the alternative to sideloading a `.cer` is to let the user trust the certificate the server presents — after seeing it. [`SMBQUICCertificateProbe`](#smbquiccertificateprobe) fetches that chain with one capture-only handshake: it never trusts the peer, never creates an SMB session, and leaves no connection behind. The app then shows the leaf's identity and fingerprint, and only a confirmed leaf becomes a `.customRoots` anchor:

```swift
import AMSMB2
import CryptoKit
import Security

// 1. Probe: one TLS handshake, nothing trusted, no SMB session (8 s default timeout).
let chain = try await SMBQUICCertificateProbe.fetchServerCertificateChain(server: "fs.example.com")
let leaf = chain[0]                                    // the server certificate, DER, leaf first

// 2. Show the user what they are about to trust: subject, SAN, validity, SHA-256.
guard let certificate = SecCertificateCreateWithData(nil, leaf as CFData) else { return }
let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "(no subject)"
let sha256 = SHA256.hash(data: leaf).map { String(format: "%02X", $0) }.joined(separator: ":")
// SAN and validity: on macOS, `SecCertificateCopyValues(certificate, nil, nil)` returns the parsed
// X.509 fields (`kSecOIDSubjectAltName`, `kSecOIDX509V1ValidityNotBefore` / `...NotAfter`).
// That API does not exist on iOS/tvOS/watchOS/visionOS — there, parse the DER yourself (a small
// ASN.1 walk of the TBSCertificate, or an X.509 library) or show subject + SHA-256 only.

// 3. The user confirms the SHA-256 OUT OF BAND (against the server admin's published fingerprint).
guard await confirmWithUser(subject: subject, sha256: sha256) else { return }

// 4. Persist the confirmed leaf (Keychain / app support), then connect with it as the anchor.
try trustStore.save(leafDER: leaf, for: "fs.example.com")
smb.transportKind = .quic
smb.quicConfiguration = SMBQUICConfiguration(trustPolicy: .customRoots([leaf]))
try await smb.connectShare(name: "Documents")
```

**Which element to persist.** For a self-signed server (e.g. Windows Server 2022's default SMB-over-QUIC certificate) the chain has one element and `chain[0]` — the leaf — is its own anchor. For a private-CA server the chain is the leaf followed by the intermediates the server sent; either the whole returned chain (`.customRoots(chain)`) or just the CA/intermediate element works as the anchor, because `.customRoots` anchors *replace* the system roots and hostname verification stays on — the server string you later connect to must still match a name in the leaf, which is one reason to show the SAN. Persisting the leaf alone also works for a private-CA server, at the cost of re-trusting on every leaf renewal.

> **First-contact caveat.** A chain fetched on first contact is only as trustworthy as the network at that moment — an on-path attacker can present their own chain, and the probe cannot tell the difference (that is precisely what it does not check). The displayed SHA-256 **must** be confirmed out of band — against the server admin's fingerprint, the server's own `Get-SmbServerCertificateMapping` output, or the exported `.cer` — before it is persisted. Once persisted, the anchor **replaces the system roots for that connection**: a wrong anchor does not weaken trust to "system or this", it silently makes the attacker's certificate the only one accepted. The probe never trusts; the user does, after confirming.

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
| 22 | `EINVAL` | Invalid argument — with `.quic` or [`SMBQUICCertificateProbe`](#smbquiccertificateprobe): a numeric target host, an invalid DER trust anchor or an empty `.customRoots([])` set (connect only), a `NaN`/infinite/non-positive `connectTimeout` or probe `timeout`, or an explicit port outside 1...65535 |
| 45 | `ENOTSUP` | Unsupported — selecting `.quic` below the QUIC availability floor or on a platform without `Network` (Linux). [`SMBQUICCertificateProbe`](#smbquiccertificateprobe) throws it on Linux (before any validation); below the Apple availability floor the probe symbol is unavailable at compile time rather than throwing. On Linux this surfaces as `EOPNOTSUPP` (same errno; `.ENOTSUP` is not a distinct `POSIXErrorCode` there). |
| 53 | `ECONNABORTED` | Transport (QUIC) `close()` called while a connect was in flight |
| 57 | `ENOTCONN` | Not connected (call `connectShare` first) |
| 60 | `ETIMEDOUT` | Operation or connect timed out — including the QUIC connect deadline (`SMBQUICConfiguration.connectTimeout`) expiring, or the [`SMBQUICCertificateProbe`](#smbquiccertificateprobe) `timeout` expiring before any certificate was captured: an unreachable or unresponsive endpoint. A QUIC TLS rejection is `EPROTO` instead; it surfaces as `ETIMEDOUT` only if the deadline expires before the handshake outcome is reported |
| 61 | `ECONNREFUSED` | Connection refused by the peer (e.g., transport connect failure) |
| 100 | `EPROTO` | QUIC TLS handshake failure — most commonly the server certificate failing the configured trust policy or hostname verification, but any other handshake rejection (e.g. an ALPN mismatch) as well. Reported promptly, ahead of the connect deadline; the Security `OSStatus` under `userInfo[NSUnderlyingErrorKey]` (an `NSError` in `NSOSStatusErrorDomain`) identifies the cause. For [`SMBQUICCertificateProbe`](#smbquiccertificateprobe): a handshake that failed before any certificate was delivered (a captured chain is returned instead of this error) |

Task cancellation surfaces as `CancellationError` (not a `POSIXError`) — see [Task Cancellation](#task-cancellation).

> Numeric values shown are Darwin (Apple) `errno` codes; the symbolic constant is what you match in `catch`. Linux assigns different numbers to the same symbols (and, as noted, lacks `.ENOTSUP` — it uses `.EOPNOTSUPP`).

---

## Task Cancellation

All `async` methods support Swift structured task cancellation. If the enclosing `Task` is cancelled:

- A fast-path check via `Task.checkCancellation()` fires before any PDU is submitted — if the task was already cancelled, `CancellationError` is thrown immediately with no network activity.
- If the task is cancelled after the PDU has been submitted, the `withTaskCancellationHandler` `onCancel` closure fires, marks the in-flight operation as abandoned, and resumes the continuation with `CancellationError`. The caller receives `CancellationError` promptly without waiting for a server response or timeout.

This means you can safely use `withTaskCancellationHandler`, `.task` modifiers, and `TaskGroup` cancellation with all AMSMB2 operations.
