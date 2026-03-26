# AMSMB2

Swift library for SMB2/3 file operations on Apple platforms (iOS 13+, macOS 10.15+, tvOS 14+, watchOS 6+, visionOS 1+) and Linux. Wraps [libsmb2](https://github.com/sahlberg/libsmb2) with a modern async/await API.

## Heritage

This is a fork of [amosavian/AMSMB2](https://github.com/amosavian/AMSMB2), the original Swift SMB2 library created by [Amir Abbas Mousavian](https://github.com/amosavian). The original library provides a solid foundation for SMB2/3 file operations with async/await support, NSSecureCoding/Codable serialization, and Objective-C compatibility.

This fork extends the original with the following improvements:

| Area | Original | This Fork |
|------|----------|-----------|
| **Public API surface** | Only `SMB2Manager` is public; internal types are inaccessible | `SMB2Client` and `SMB2FileHandle` exposed as public API for direct file handle operations |
| **Thread safety** | Context access unprotected in some paths; file handle close/deinit has race conditions | Serial event loop queue exclusively owns `smb2_context`; `DispatchSource`-based socket monitoring; nil-swap close pattern prevents double-close races; `smbClient` getter validates connection under lock |
| **Performance** | Single-threaded poll loop blocks during each operation; only one operation at a time | Event loop + `DispatchSource` I/O allows multiple in-flight operations; `BufferPool` eliminates per-read allocation; pipelined read/write dispatch concurrent chunks via `DispatchGroup`; `AsyncInputStream` backpressure bounds memory during streaming |
| **Server-side copy** | Sends copy chunks using negotiated write size (~8 MB), exceeding the MS-SMB2 spec limit | Chunks capped at 1 MiB per MS-SMB2 section 3.3.5.15.6.2 — works with all spec-compliant servers |
| **Symlink creation** | `ReparseDataLength` omits 12-byte symlink header, causing `STATUS_IO_REPARSE_DATA_INVALID` on Samba 4.21+ | Correct reparse data format per MS-FSCC 2.1.2.4 |
| **Change Notify** | Crashes (signal 5/11) due to re-entrant `smb2_close()` inside callback + dangling `withUnsafeMutablePointer` | Direct PDU construction bypasses re-entrant wrapper; `Unmanaged<CBData>` for safe C callback pointers |
| **Testing** | Single test file; `swift test` crashes without server env vars; no Docker infrastructure | 76 tests across 6 files; `swift test` works without a server (skips integration tests); Docker-based `make integrationtest` |
| **Documentation** | Minimal README with outdated examples | Architecture guide with Mermaid diagrams, comprehensive API reference, modern async/await examples |

## Features

- Connect to SMB2/3 shares with NTLM authentication
- List, create, remove directories (recursive)
- Read, write, append, truncate files with progress reporting
- Upload/download between local filesystem and SMB share
- Server-side copy and move operations
- Symbolic link creation and resolution
- File system and item attribute queries
- Change Notify (file monitoring)
- Streaming writes via `AsyncSequence` with backpressure flow control
- Pipelined read/write for high-throughput file transfers
- `NSSecureCoding` and `Codable` support for connection serialization (passwords intentionally excluded for security)
- Objective-C compatibility layer
- Direct access to `SMB2Client` and `SMB2FileHandle` for advanced use cases

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/simplekube-ro/AMSMB2", branch: "master")
]
```

Then add the product dependency to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "AMSMB2", package: "AMSMB2"),
    ]
)
```

## Quick Start

```swift
import AMSMB2

// Create a manager
let url = URL(string: "smb://192.168.1.100")!
let credential = URLCredential(user: "username", password: "password", persistence: .forSession)
let smb = SMB2Manager(url: url, credential: credential)!

// Connect to a share
try await smb.connectShare(name: "Documents")

// List directory contents
let files = try await smb.contentsOfDirectory(atPath: "/")
for file in files {
    print(file.name ?? "?", file.fileSize ?? 0)
}

// Read a file
let data = try await smb.contents(atPath: "/report.pdf", progress: nil)

// Write a file
try await smb.write(data: data, toPath: "/backup/report.pdf", progress: nil)

// Upload a local file
let localURL = URL(fileURLWithPath: "/tmp/photo.jpg")
try await smb.uploadItem(at: localURL, toPath: "/photos/photo.jpg", progress: nil)

// Download a file
let downloadURL = URL(fileURLWithPath: "/tmp/downloaded.pdf")
try await smb.downloadItem(atPath: "/report.pdf", to: downloadURL, progress: nil)

// Disconnect
try await smb.disconnectShare()
```

## Testing

### Prerequisites

```bash
git submodule update --init    # Required — fetches the libsmb2 C library
```

### Unit Tests (no server required)

```bash
swift test
```

Runs 32 unit tests. Integration tests are automatically skipped when no SMB server is configured.

### Integration Tests (requires Docker)

```bash
make integrationtest
```

Starts a Samba container, runs the full test suite (76 tests), and tears down. Requires Docker Desktop.

### Linux Tests

```bash
make linuxtest        # Uses local volume mount
make cleanlinuxtest   # Clean Docker build
```

## Documentation

- **[Architecture](docs/ARCHITECTURE.md)** — Layer stack, event loop model, socket monitoring, buffer pool, pipelined I/O, thread safety model
- **[API Reference](docs/API.md)** — Complete reference for all public types and methods

## License

The source code in this repository is MIT licensed. However, it links to [libsmb2](https://github.com/sahlberg/libsmb2) which is LGPL v2.1. The library is configured as a **dynamic** framework (`.dynamic` in Package.swift) to comply with LGPL requirements for App Store distribution.

You **must** link this library dynamically if you distribute your app on the App Store.
