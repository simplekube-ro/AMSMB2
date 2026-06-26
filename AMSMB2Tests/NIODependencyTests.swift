// NIODependencyTests.swift
// AMSMB2
//
// Copyright © 2024 Mousavian. Distributed under MIT license.
// All rights reserved.
//
// Compile-time smoke tests that verify SwiftNIO and NIOTransportServices are
// resolved and importable on Apple platforms (T3 / issue #22).
//
// These tests are guarded by `#if canImport(Network)` so they are a no-op on
// Linux, which keeps the legacy libsmb2-owned TCP path and never imports NIO.
//
// Acceptance criteria (issue #22 / T3):
//   - `swift build --disable-sandbox` resolves NIOCore and NIOTransportServices
//   - All NIO imports are platform-guarded; Linux build path is unaffected

#if canImport(Network)
import NIOCore
import NIOTransportServices
import XCTest

final class NIODependencyTests: XCTestCase, @unchecked Sendable {

    // MARK: - NIOCore availability

    /// Verifies that NIOCore is resolved and ByteBuffer is usable.
    /// If the package dependency is missing this file will not compile on Apple.
    func testNIOCoreByteBufferIsAccessible() {
        // ByteBuffer is the canonical NIOCore value type; its presence proves
        // NIOCore was resolved and linked correctly.
        var buffer = ByteBuffer()
        buffer.writeString("smb2")
        XCTAssertEqual(buffer.readableBytes, 4)
    }

    // MARK: - NIOTransportServices availability

    /// Verifies that NIOTransportServices is resolved and NIOTSEventLoopGroup
    /// is constructable (it is the NIO entry point for Network.framework).
    func testNIOTSEventLoopGroupIsConstructable() throws {
        // NIOTSEventLoopGroup wraps a Network.framework dispatch queue.
        // Construction proves the target linked correctly.
        let group = NIOTSEventLoopGroup(loopCount: 1)
        defer { try? group.syncShutdownGracefully() }
        XCTAssertEqual(group.makeIterator().reduce(0) { acc, _ in acc + 1 }, 1)
    }
}
#endif
