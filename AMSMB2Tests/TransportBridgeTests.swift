//
//  TransportBridgeTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Unit tests for the TransportBridge (T5 / issue #24).
//
//  These tests are Apple-only (#if canImport(Network)) because TransportBridge
//  is guarded the same way per design D7.
//
//  Acceptance criteria (issue #24 / T5):
//    - ext struct is populated with non-null C trampolines
//    - Bytes pushed through C send callback arrive at SMBTransport (copy-at-boundary)
//    - Bytes received from SMBTransport are drainable via C recv callback
//    - C recv returns EAGAIN (would-block) when inbound buffer is empty and open
//    - C recv returns 0 on graceful EOF
//    - Clean teardown: after close, recv returns ECONNRESET
//    - Zero Swift 6 strict-concurrency warnings
//
//  IMPORTANT — MockTransport loopback semantics:
//  MockTransport is a loopback: `send(_:)` delivers bytes to `receive()`. When both
//  outbound and inbound pumps are running concurrently, the inbound pump's waiting
//  `receive()` call will consume bytes that the outbound pump writes via `transport.send(_:)`
//  before the test's own `mock.receive()` call can get them. To avoid this:
//    - Outbound-path tests use `startOutboundPump()` (no inbound pump competing).
//    - Inbound-path tests use `startInboundPump()` (or both pumps — test sends directly).
//    - Full-loopback tests start both pumps and exercise C send → outbound → mock →
//      inbound → bridge buffer → C recv (complete loopback through both pumps).
//
//  Requires: import SMB2 (C symbols not re-exported via @testable import AMSMB2)
//

#if canImport(Network)

import SMB2
import XCTest

@testable import AMSMB2

final class TransportBridgeTests: XCTestCase, @unchecked Sendable {

    // MARK: - Scenario: ext struct is populated with trampolines

    /// WHEN the bridge produces its smb2_external_transport
    /// THEN all four function-pointer fields are non-null
    /// AND userdata is the Unmanaged opaque pointer to the bridge
    func testExtStructHasNonNullCallbacks() throws {
        let mock = MockTransport()
        let bridge = TransportBridge(transport: mock)
        let ext = bridge.makeExternalTransport()

        XCTAssertNotNil(ext.userdata, "userdata must be the bridge's Unmanaged opaque pointer")
        XCTAssertNotNil(ext.connect, "connect trampoline must be non-nil")
        XCTAssertNotNil(ext.send, "send trampoline must be non-nil")
        XCTAssertNotNil(ext.recv, "recv trampoline must be non-nil")
        XCTAssertNotNil(ext.close, "close trampoline must be non-nil")

        // Balance the passRetained from makeExternalTransport().
        _ = ext.close?(ext.userdata)
    }

    // MARK: - Scenario: send returns immediately and is delivered asynchronously

    /// WHEN the C send callback enqueues bytes
    /// THEN it returns the byte count without blocking on the network
    /// AND the outbound pump subsequently delivers those bytes to the transport
    ///
    /// Only the OUTBOUND pump runs in this test so that the inbound pump does not
    /// compete for the MockTransport's receive() and steal the outbound-delivered bytes.
    func testSendReturnsByteCountImmediately() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let bridge = TransportBridge(transport: mock)
        bridge.startOutboundPump()          // outbound only; inbound pump NOT started
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let sentLen: Int32 = payload.withUnsafeBufferPointer { ptr in
            ext.send!(ext.userdata, ptr.baseAddress, ptr.count)
        }
        XCTAssertEqual(
            sentLen, Int32(payload.count),
            "send must return the full byte count immediately"
        )

        // Outbound pump delivers bytes to transport.send(_:) asynchronously.
        // With no inbound pump running, mock.receive() sees the bytes from the queue.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        let delivered = try await mock.receive()
        XCTAssertEqual(
            delivered, Data(payload),
            "outbound pump must deliver bytes to the transport"
        )
    }

    // MARK: - Scenario: Sent bytes survive immediate buffer reuse (copy-at-boundary)

    /// WHEN the C send callback is invoked and the caller overwrites the source buffer
    ///      immediately after send returns
    /// THEN the bytes delivered to the SMBTransport match the original contents
    ///
    /// Only the OUTBOUND pump runs in this test to avoid inbound-pump contention.
    func testSentBytesSurviveImmediateBufferReuse() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let bridge = TransportBridge(transport: mock)
        bridge.startOutboundPump()          // outbound only; inbound pump NOT started
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        // Original bytes to send.
        var srcBuf: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let sentLen: Int32 = srcBuf.withUnsafeBufferPointer { ptr in
            ext.send!(ext.userdata, ptr.baseAddress, ptr.count)
        }
        XCTAssertEqual(sentLen, 8)

        // Overwrite source buffer immediately after send returns, before any async work.
        // If the bridge stored a reference instead of a copy, the transport would receive zeros.
        for idx in srcBuf.indices { srcBuf[idx] = 0 }

        // Give the outbound pump time to drain into the mock transport.
        // No inbound pump running, so mock.receive() gets the bytes.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // Bytes delivered must be the originals [1..8], not the overwritten zeros.
        let delivered = try await mock.receive()
        XCTAssertEqual(
            delivered, Data([1, 2, 3, 4, 5, 6, 7, 8]),
            "copy-at-boundary: bridge must copy bytes before send returns"
        )
    }

    // MARK: - Scenario: recv returns buffered bytes

    /// WHEN the inbound pump has appended bytes and C recv is called
    /// THEN up to maxLen bytes are copied into the C buffer and that count is returned
    func testRecvDrainsInboundBytes() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let bridge = TransportBridge(transport: mock)
        bridge.startInboundPump()           // inbound only; outbound pump NOT started
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        // Push bytes from the "network" side into the mock. MockTransport.send(_:) delivers
        // directly to a suspended receive() if one is waiting (the inbound pump's call), which
        // then appends to the bridge's inbound buffer.
        let serverData = Data("hello from server".utf8)
        try await mock.send(serverData)

        // Wait for the inbound pump to deliver bytes to the bridge inbound buffer.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // C recv drains synchronously.
        var recvBuf = [UInt8](repeating: 0, count: 64)
        let count: Int32 = recvBuf.withUnsafeMutableBufferPointer { ptr in
            ext.recv!(ext.userdata, ptr.baseAddress, ptr.count)
        }

        XCTAssertEqual(count, Int32(serverData.count), "recv must return the byte count")
        XCTAssertEqual(
            Data(recvBuf.prefix(Int(count))), serverData,
            "recv must deliver the exact bytes from the transport"
        )
    }

    // MARK: - Scenario: recv would-block when empty and open

    /// WHEN C recv is called while the inbound store is empty and the transport is still open
    /// THEN it returns the would-block signal (does not block, does not return 0)
    func testRecvWouldBlockWhenEmptyAndOpen() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let bridge = TransportBridge(transport: mock)
        bridge.startPumps()
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        // No data pushed; inbound buffer is empty; transport is open.
        var recvBuf = [UInt8](repeating: 0, count: 64)
        let count: Int32 = recvBuf.withUnsafeMutableBufferPointer { ptr in
            ext.recv!(ext.userdata, ptr.baseAddress, ptr.count)
        }

        XCTAssertLessThan(count, 0, "recv must return negative to signal would-block")
        // errno is set synchronously by cRecv before returning; no await between the call and
        // this check, so errno is from our cRecv call (thread-local, same thread).
        XCTAssertEqual(errno, EAGAIN, "would-block must set errno = EAGAIN")
    }

    // MARK: - Scenario: recv returns 0 on graceful EOF

    /// WHEN the transport reports graceful EOF (empty Data) and the inbound store is drained
    /// THEN C recv returns 0
    func testRecvReturnsZeroOnGracefulEOF() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let bridge = TransportBridge(transport: mock)
        bridge.startInboundPump()           // inbound only
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        // Signal graceful EOF from the "server" side.
        await mock.signalGracefulEOF()

        // Wait for the inbound pump to process the EOF.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        var recvBuf = [UInt8](repeating: 0, count: 64)
        let count: Int32 = recvBuf.withUnsafeMutableBufferPointer { ptr in
            ext.recv!(ext.userdata, ptr.baseAddress, ptr.count)
        }

        XCTAssertEqual(count, 0, "recv must return 0 to signal graceful EOF")
    }

    // MARK: - Scenario: Cancellation tears down cleanly

    /// WHEN the close callback fires
    /// THEN both pump tasks stop, the transport is closed, and recv returns an error
    func testCloseTearsDownCleanly() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let bridge = TransportBridge(transport: mock)
        bridge.startPumps()
        let ext = bridge.makeExternalTransport()

        // Close via the C callback (balances the passRetained; bridge is still alive here
        // because this test holds its own strong reference via `bridge`).
        _ = ext.close?(ext.userdata)

        // Brief pause for async teardown Tasks to schedule.
        try await Task.sleep(nanoseconds: 20_000_000) // 20 ms

        // After close, cRecv must return a negative error, not EAGAIN or 0.
        var recvBuf = [UInt8](repeating: 0, count: 64)
        let count: Int32 = recvBuf.withUnsafeMutableBufferPointer { ptr in
            bridge.cRecv(buf: ptr.baseAddress, maxLen: ptr.count)
        }
        XCTAssertLessThan(count, 0, "after close, recv must return negative")
        XCTAssertEqual(errno, ECONNRESET, "after close, recv must set errno = ECONNRESET")
    }

    // MARK: - Scenario: connect trampoline reports state, never connects (ordering fix)

    /// WHEN the C connect trampoline is invoked BEFORE the transport has been connected
    /// THEN it reports failure (`< 0`) — it must NOT claim "connected" prematurely
    /// AND AFTER an eager `bridge.connect(...)` succeeds it reports success (`0`)
    /// AND it never initiates a second transport connect (no double-connect).
    ///
    /// This pins the fix-seam-connect-ordering invariant: libsmb2's `ext_connect` only fires
    /// NEGOTIATE on a `>= 0` return, so the trampoline may report success only after the channel
    /// is live. The old `kickConnect` returned `0` unconditionally — the root-cause defect.
    func testConnectTrampolineReportsStateOnly() async throws {
        let mock = MockTransport()
        let bridge = TransportBridge(transport: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        // Before the eager connect: the trampoline must report failure, not premature success.
        let before: Int32 = "localhost".withCString { hostPtr in
            ext.connect!(ext.userdata, hostPtr, 445)
        }
        XCTAssertLessThan(before, 0, "trampoline must report failure before the transport connects")

        // Establish the transport eagerly (what connectWithBridge does on the caller's task).
        try await bridge.connect(host: "localhost", port: 445)

        // After the transport is live: the trampoline reports success.
        let after: Int32 = "localhost".withCString { hostPtr in
            ext.connect!(ext.userdata, hostPtr, 445)
        }
        XCTAssertEqual(after, 0, "trampoline must report success once the transport is connected")
    }

    // MARK: - Scenario: Round-trip through C callbacks via MockTransport (loopback)

    /// WHEN bytes are pushed through C send
    /// THEN they traverse: cSend → outbound pump → transport.send → (MockTransport loopback)
    ///      → inbound pump → bridge inbound buffer → cRecv
    /// AND the bytes arrive intact at C recv (no real socket, no server)
    ///
    /// MockTransport is a loopback: bytes written via transport.send(_:) become available
    /// via transport.receive(). With BOTH pumps running, the outbound pump delivers bytes
    /// to MockTransport, the inbound pump picks them up, and C recv drains them.
    func testFullLoopbackThroughBothPumps() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let bridge = TransportBridge(transport: mock)
        bridge.startPumps()                 // both pumps: outbound + inbound
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let payload: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        let sent: Int32 = payload.withUnsafeBufferPointer { ptr in
            ext.send!(ext.userdata, ptr.baseAddress, ptr.count)
        }
        XCTAssertEqual(sent, Int32(payload.count), "send must return full byte count")

        // Allow the full chain to run:
        //   outbound pump drains → transport.send(payload) → MockTransport.send delivers to
        //   inbound pump's waiting receive() → inbound pump appends to bridge inbound buffer.
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms

        var recvBuf = [UInt8](repeating: 0, count: 64)
        let count: Int32 = recvBuf.withUnsafeMutableBufferPointer { ptr in
            ext.recv!(ext.userdata, ptr.baseAddress, ptr.count)
        }

        XCTAssertEqual(count, Int32(payload.count), "recv must return the byte count")
        XCTAssertEqual(
            Data(recvBuf.prefix(Int(count))), Data(payload),
            "bytes must survive loopback: cSend → outbound → mock → inbound → cRecv"
        )
    }

    // MARK: - Scenario: double-start guard prevents task leaks

    /// WHEN startOutboundPump() (or startInboundPump()) is called a second time
    /// THEN the second call is a no-op — the guard returns early without creating a second task
    /// AND the bridge still tears down cleanly after close()
    ///
    /// This verifies the lock-guarded `guard outboundPumpTask == nil` / `guard inboundPumpTask == nil`
    /// path added to prevent accidental task leaks on repeated start calls.
    func testDoubleStartIsNoOp() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let bridge = TransportBridge(transport: mock)

        // Call both start methods twice — second calls must be silent no-ops, not crash or leak.
        bridge.startOutboundPump()
        bridge.startOutboundPump()
        bridge.startInboundPump()
        bridge.startInboundPump()

        let ext = bridge.makeExternalTransport()
        // Close via the C trampoline to balance passRetained.
        _ = ext.close?(ext.userdata)

        // After close, cRecv must return ECONNRESET — confirming clean teardown despite double start.
        try await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        var recvBuf = [UInt8](repeating: 0, count: 64)
        let result: Int32 = recvBuf.withUnsafeMutableBufferPointer { ptr in
            bridge.cRecv(buf: ptr.baseAddress, maxLen: ptr.count)
        }
        XCTAssertLessThan(result, 0, "after close, recv must return negative")
        XCTAssertEqual(errno, ECONNRESET, "after close, recv must set errno = ECONNRESET")
    }
}

#endif // canImport(Network)
