# NIO Package.swift Apple-only dependency pattern (T3 #22)

## Resolved versions (2026-06)
- swift-nio: 2.101.2 (pinned from "2.65.0")
- swift-nio-transport-services: 1.28.0 (pinned from "1.21.0")

## Package.swift dep declaration
```swift
// In package-level dependencies:
.package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.65.0")),
.package(
    url: "https://github.com/apple/swift-nio-transport-services.git",
    .upToNextMajor(from: "1.21.0")
),

// In target dependencies (both AMSMB2 and AMSMB2Tests):
.product(
    name: "NIOCore",
    package: "swift-nio",
    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .macCatalyst])
),
.product(
    name: "NIOTransportServices",
    package: "swift-nio-transport-services",
    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .macCatalyst])
),
```

## Source guard
All NIO imports in Swift source and test files must be wrapped:
```swift
#if canImport(Network)
import NIOCore
import NIOTransportServices
// ... NIO-using code ...
#endif
```

## Key constraint (D1 in design.md — naming trap)
`SMB2_TRANSPORT_TCP == 0` selects libsmb2's built-in socket and IGNORES the ext struct.
To route NIO traffic through the seam: use `SMB2_TRANSPORT_QUIC` or `SMB2_TRANSPORT_AUTO`
with a populated `smb2_external_transport` ext. NEVER pass `SMB2_TRANSPORT_TCP` to
`smb2_set_transport` when intending to use the NIO seam.

## Test target also needs NIO deps
The smoke test (NIODependencyTests.swift) imports NIOCore and NIOTransportServices directly.
The AMSMB2Tests target must list both products with the same `.when(platforms:)` guard.
Test: `ByteBuffer` (NIOCore) and `NIOTSEventLoopGroup` (NIOTransportServices) constructable.

## Package.resolved is gitignored
Do not commit Package.resolved. Pinning is declared via .upToNextMajor in Package.swift.

## Linux build
Linux toolchain not available in this dev environment. Correctness confirmed by the
`.when(platforms:)` guard that excludes both NIO products from Linux targets, matching
the `#if canImport(Network)` source guards in all NIO-using files.
