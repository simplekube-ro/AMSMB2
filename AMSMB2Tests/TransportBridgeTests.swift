//
//  TransportBridgeTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Unit tests for the TransportBridge (T5 / issue #24, push-converted by #45).
//
//  These tests are Apple-only (#if canImport(Network)) because TransportBridge
//  is guarded the same way per design D7.
//
//  Acceptance criteria (issue #24 / T5, as amended by #45):
//    - ext struct is populated with non-null C trampolines
//    - Bytes pushed through C send callback arrive at SMBTransport (copy-at-boundary)
//    - Bytes the transport delivers are drainable via C recv callback
//    - C recv returns EAGAIN (would-block) when inbound buffer is empty and open
//    - C recv returns 0 on graceful EOF
//    - Clean teardown: after close, recv returns ECONNRESET
//    - Zero Swift 6 strict-concurrency warnings
//
//  IMPORTANT — MockTransport is push-shaped, not a loopback:
//  `send(_:)` records bytes in the mock's sent log (read with `sentChunks()` /
//  `waitForSent(count:)`); inbound data is injected by the test with `deliver(_:)`,
//  `signalGracefulEOF()` and `signalError(_:)`, which invoke the handler the bridge
//  supplied to `connect(host:port:onReceive:)`. The two directions never cross, so no
//  test needs to suppress a loopback and every inbound delivery is synchronous: once
//  `await mock.deliver(...)` returns, the bridge's store and signal have already been
//  updated — no sleeps, no expectations.
//
//  Requires: import SMB2 (C symbols not re-exported via @testable import AMSMB2)
//

#if canImport(Network)

import SMB2
import XCTest

@testable import AMSMB2

final class TransportBridgeTests: XCTestCase, @unchecked Sendable {

    // MARK: - Helpers

    /// A bridge already connected to `mock` — i.e. the mock holds the bridge's inbound handler,
    /// which is what every push-path test needs before it can inject anything.
    private func connectedBridge(
        to mock: MockTransport
    ) async throws -> TransportBridge {
        let bridge = TransportBridge(transport: mock)
        try await bridge.connect(host: "localhost", port: 445)
        return bridge
    }

    /// Drains the bridge through the C recv trampoline, returning `(result, bytes)`.
    private func drain(_ ext: smb2_external_transport, maxLen: Int = 64) -> (Int32, Data) {
        var buffer = [UInt8](repeating: 0, count: maxLen)
        let count: Int32 = buffer.withUnsafeMutableBufferPointer { pointer in
            ext.recv!(ext.userdata, pointer.baseAddress, pointer.count)
        }
        return (count, count > 0 ? Data(buffer.prefix(Int(count))) : Data())
    }

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
    func testSendReturnsByteCountImmediately() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        bridge.startOutboundPump()
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let sentLen: Int32 = payload.withUnsafeBufferPointer { pointer in
            ext.send!(ext.userdata, pointer.baseAddress, pointer.count)
        }
        XCTAssertEqual(
            sentLen, Int32(payload.count),
            "send must return the full byte count immediately"
        )

        // The outbound pump delivers to transport.send(_:) asynchronously; the mock's sent log
        // is the observation point (there is no loopback to read from).
        await mock.waitForSent(count: 1)
        let delivered = await mock.sentChunks()
        XCTAssertEqual(
            delivered, [Data(payload)],
            "outbound pump must deliver bytes to the transport"
        )
    }

    // MARK: - Scenario: Sent bytes survive immediate buffer reuse (copy-at-boundary)

    /// WHEN the C send callback is invoked and the caller overwrites the source buffer
    ///      immediately after send returns
    /// THEN the bytes delivered to the SMBTransport match the original contents
    func testSentBytesSurviveImmediateBufferReuse() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        bridge.startOutboundPump()
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        var sourceBuffer: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let sentLen: Int32 = sourceBuffer.withUnsafeBufferPointer { pointer in
            ext.send!(ext.userdata, pointer.baseAddress, pointer.count)
        }
        XCTAssertEqual(sentLen, 8)

        // Overwrite the source buffer immediately after send returns, before any async work.
        // If the bridge stored a reference instead of a copy, the transport would receive zeros.
        for index in sourceBuffer.indices { sourceBuffer[index] = 0 }

        await mock.waitForSent(count: 1)
        let delivered = await mock.sentChunks()
        XCTAssertEqual(
            delivered, [Data([1, 2, 3, 4, 5, 6, 7, 8])],
            "copy-at-boundary: bridge must copy bytes before send returns"
        )
    }

    // MARK: - Scenario: recv returns buffered bytes

    /// WHEN the transport has delivered bytes and C recv is called
    /// THEN up to maxLen bytes are copied into the C buffer and that count is returned
    func testRecvDrainsInboundBytes() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let serverData = Data("hello from server".utf8)
        await mock.deliver(serverData)

        // No sleep: the delivery ran the bridge's handler synchronously before `deliver` returned.
        let (count, bytes) = drain(ext)
        XCTAssertEqual(count, Int32(serverData.count), "recv must return the byte count")
        XCTAssertEqual(bytes, serverData, "recv must deliver the exact bytes from the transport")
    }

    // MARK: - Scenario: recv would-block when empty and open

    /// WHEN C recv is called while the inbound store is empty and the transport is still open
    /// THEN it returns the would-block signal (does not block, does not return 0)
    func testRecvWouldBlockWhenEmptyAndOpen() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let (count, _) = drain(ext)
        XCTAssertLessThan(count, 0, "recv must return negative to signal would-block")
        // errno is set synchronously by cRecv before returning; no await between the call and
        // this check, so errno is from our cRecv call (thread-local, same thread).
        XCTAssertEqual(errno, EAGAIN, "would-block must set errno = EAGAIN")
    }

    // MARK: - Scenario: recv returns 0 on graceful EOF

    /// WHEN the transport delivered graceful EOF (empty Data) and the inbound store is drained
    /// THEN C recv returns 0
    func testRecvReturnsZeroOnGracefulEOF() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        await mock.signalGracefulEOF()

        let (count, _) = drain(ext)
        XCTAssertEqual(count, 0, "recv must return 0 to signal graceful EOF")
    }

    /// WHEN bytes were delivered before graceful EOF
    /// THEN recv drains the bytes first and only then reports EOF (precedence: bytes → EOF)
    func testRecvDrainsBufferedBytesBeforeReportingEOF() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let payload = Data("tail".utf8)
        await mock.deliver(payload)
        await mock.signalGracefulEOF()

        let (first, bytes) = drain(ext)
        XCTAssertEqual(first, Int32(payload.count))
        XCTAssertEqual(bytes, payload)
        let (second, _) = drain(ext)
        XCTAssertEqual(second, 0, "EOF is reported only after the buffered bytes are drained")
    }

    // MARK: - Scenario: Cancellation tears down cleanly

    /// WHEN the close callback fires
    /// THEN the outbound pump task stops, the transport is closed, and recv returns an error
    func testCloseTearsDownCleanly() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        bridge.startOutboundPump()
        let ext = bridge.makeExternalTransport()

        // Close via the C callback (balances the passRetained; bridge is still alive here
        // because this test holds its own strong reference via `bridge`).
        _ = ext.close?(ext.userdata)

        // After close, cRecv must return a negative error, not EAGAIN or 0.
        var recvBuf = [UInt8](repeating: 0, count: 64)
        let count: Int32 = recvBuf.withUnsafeMutableBufferPointer { pointer in
            bridge.cRecv(buf: pointer.baseAddress, maxLen: pointer.count)
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

    // MARK: - Scenario: Round-trip through C callbacks via MockTransport

    /// WHEN bytes are pushed through C send AND inbound bytes are injected through the mock
    /// THEN the outbound bytes reach `transport.send(_:)` and the inbound bytes are drainable
    ///      through C recv — both directions, no real socket, no server
    func testRoundTripThroughCCallbacksViaMockTransport() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        bridge.startOutboundPump()
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let outbound: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        let sent: Int32 = outbound.withUnsafeBufferPointer { pointer in
            ext.send!(ext.userdata, pointer.baseAddress, pointer.count)
        }
        XCTAssertEqual(sent, Int32(outbound.count), "send must return full byte count")
        await mock.waitForSent(count: 1)
        let delivered = await mock.sentChunks()
        XCTAssertEqual(delivered, [Data(outbound)], "outbound bytes reach the transport")

        let inbound = Data([0x11, 0x22, 0x33])
        await mock.deliver(inbound)
        let (count, bytes) = drain(ext)
        XCTAssertEqual(count, Int32(inbound.count))
        XCTAssertEqual(bytes, inbound, "inbound bytes are drainable through C recv")
    }

    // MARK: - Scenario: double-start guard prevents task leaks

    /// WHEN startOutboundPump() is called a second time
    /// THEN the second call is a no-op — the guard returns early without creating a second task
    /// AND the bridge still tears down cleanly after close()
    func testDoubleStartIsNoOp() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)

        // Second call must be a silent no-op, not a crash or a leaked task.
        bridge.startOutboundPump()
        bridge.startOutboundPump()

        let ext = bridge.makeExternalTransport()
        // Close via the C trampoline to balance passRetained.
        _ = ext.close?(ext.userdata)

        var recvBuf = [UInt8](repeating: 0, count: 64)
        let result: Int32 = recvBuf.withUnsafeMutableBufferPointer { pointer in
            bridge.cRecv(buf: pointer.baseAddress, maxLen: pointer.count)
        }
        XCTAssertLessThan(result, 0, "after close, recv must return negative")
        XCTAssertEqual(errno, ECONNRESET, "after close, recv must set errno = ECONNRESET")
    }

    // MARK: - Scenario: recv gathers bytes across multiple delivered inbound chunks
    //
    // These three tests pin the inbound-buffering contract that the chunk-FIFO refactor
    // (replacing the contiguous `inboundBuffer: Data` + `removeSubrange(..<count)` front-drain
    // with a `[Data]` FIFO + head cursor) must preserve byte-for-byte. They fail against the
    // naive-FIFO mistakes (returning only the head chunk, or indexing a non-zero-startIndex
    // chunk with absolute offsets).

    /// WHEN several distinct chunks have been delivered (each its own FIFO entry)
    /// AND a single C recv is issued with `maxLen` larger than the total buffered
    /// THEN recv gathers ALL buffered bytes across chunk boundaries, in FIFO order, in one call.
    func testRecvGathersBytesAcrossMultipleBufferedChunks() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let firstChunk = Data("AAAA".utf8)      // 4
        let secondChunk = Data("BBBBBB".utf8)   // 6
        let thirdChunk = Data("CC".utf8)        // 2
        await mock.deliver(firstChunk)
        await mock.deliver(secondChunk)
        await mock.deliver(thirdChunk)

        let (count, bytes) = drain(ext)
        XCTAssertEqual(
            count, Int32(firstChunk.count + secondChunk.count + thirdChunk.count),
            "a single recv with ample maxLen must gather all buffered chunks"
        )
        XCTAssertEqual(
            bytes, firstChunk + secondChunk + thirdChunk,
            "recv must reassemble bytes across chunk boundaries in FIFO order"
        )
    }

    /// WHEN buffered chunks are drained by successive recv calls whose `maxLen` lands in the
    ///      MIDDLE of a chunk
    /// THEN the read cursor advances across the chunk boundary so the next recv resumes exactly
    ///      where the previous one stopped — no bytes dropped, duplicated, or reordered.
    func testRecvPartialDrainAdvancesCursorAcrossChunkBoundary() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        await mock.deliver(Data("AAAA".utf8))    // 4
        await mock.deliver(Data("BBBBBB".utf8))  // 6
        await mock.deliver(Data("CC".utf8))      // 2  → 12 total

        // First recv: maxLen 5 → 4 bytes from chunk one + 1 byte from chunk two.
        let (firstCount, firstBytes) = drain(ext, maxLen: 5)
        XCTAssertEqual(firstCount, 5, "first recv returns maxLen bytes when more are buffered")
        XCTAssertEqual(firstBytes, Data("AAAAB".utf8))

        // Second recv: drains the remainder — 5 bytes from chunk two + 2 from chunk three.
        let (secondCount, secondBytes) = drain(ext)
        XCTAssertEqual(secondCount, 7, "second recv resumes exactly where the first stopped")
        XCTAssertEqual(secondBytes, Data("BBBBBCC".utf8))
    }

    /// WHEN a delivered chunk is a `Data` slice with a NON-ZERO `startIndex` (as produced by
    ///      slicing inbound bytes — `ByteBuffer.readableBytesView`-derived Data can be such)
    /// THEN recv copies the slice's logical bytes, honoring its index range — never indexing
    ///      with absolute offsets (which would SIGTRAP or corrupt under a by-reference FIFO).
    func testRecvHandlesNonZeroStartIndexChunk() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let backing = Data((0..<32).map { UInt8($0) })
        let slice = backing[8...] // startIndex == 8, 24 bytes: values 8...31
        XCTAssertNotEqual(slice.startIndex, 0, "precondition: slice must have a non-zero startIndex")
        await mock.deliver(slice)

        let (count, bytes) = drain(ext)
        XCTAssertEqual(count, 24, "recv must return the slice's logical byte count")
        XCTAssertEqual(
            bytes, Data((8...31).map { UInt8($0) }),
            "recv must copy a non-zero-startIndex chunk by honoring its index range"
        )
    }

    // MARK: - Scenario: the inbound-ready signal fires inside the delivery

    /// WHEN the transport delivers a chunk
    /// THEN the chunk is in the store and the signal has fired before the delivery returned —
    ///      no task, no executor hop, nothing to wait for.
    ///
    /// WHY the synchronous assertion: an `XCTestExpectation` would also pass if the signal were
    /// posted from a task later; asserting immediately after `await mock.deliver(...)` returns is
    /// what pins "no executor hop between the transport and the store".
    func testInboundReadySignalFiresInsideTheDelivery() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let signals = LockedBox<Int>(0)
        bridge.setInboundReadyHandler { signals.mutate { $0 += 1 } }
        XCTAssertEqual(signals.value, 0, "registering against an empty store must not signal")

        let payload = Data("chunk".utf8)
        await mock.deliver(payload)

        XCTAssertEqual(signals.value, 1, "the delivery fires exactly one signal, synchronously")
        let (count, bytes) = drain(ext)
        XCTAssertEqual(count, Int32(payload.count))
        XCTAssertEqual(bytes, payload)
    }

    /// WHEN the inbound-ready handler is registered while the store is empty and open
    /// THEN no signal fires until the first delivery
    func testRegistrationWithEmptyStoreDoesNotSignal() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let signals = LockedBox<Int>(0)
        bridge.setInboundReadyHandler { signals.mutate { $0 += 1 } }
        XCTAssertEqual(signals.value, 0, "an empty open store must not signal at registration")
    }

    // MARK: - Scenario: a delivery before registration is not a lost wakeup

    /// WHEN a chunk is delivered after connect but BEFORE the inbound-ready handler is registered
    /// THEN registering the handler fires exactly one signal, and C recv then returns the bytes.
    ///
    /// WHY this is the lost-wakeup test: `serviceContextForSeam` is the only path that services
    /// with `POLLIN`, and it runs only from this signal. A chunk sitting in the store with no
    /// signal is drained only by a *later* delivery — and if it is the last one, the connect hangs
    /// to its timeout. Asserting the bytes alone would pass even with the wakeup lost, so the
    /// signal count is the assertion that matters here.
    func testDeliveryBeforeRegistrationSignalsExactlyOnceAtRegistration() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let payload = Data("early".utf8)
        await mock.deliver(payload)

        let signals = LockedBox<Int>(0)
        bridge.setInboundReadyHandler { signals.mutate { $0 += 1 } }
        XCTAssertEqual(signals.value, 1, "registration must fire exactly one signal for a non-empty store")

        let (count, bytes) = drain(ext)
        XCTAssertEqual(count, Int32(payload.count))
        XCTAssertEqual(bytes, payload)
    }

    /// The EOF flavour of the same window: an EOF that lands before registration must still wake
    /// the servicing loop when the handler is installed.
    func testEOFBeforeRegistrationSignalsExactlyOnceAtRegistration() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        await mock.signalGracefulEOF()

        let signals = LockedBox<Int>(0)
        bridge.setInboundReadyHandler { signals.mutate { $0 += 1 } }
        XCTAssertEqual(signals.value, 1, "a pre-registration EOF must signal at registration")

        let (count, _) = drain(ext)
        XCTAssertEqual(count, 0, "recv reports EOF on the next drain")
    }

    /// The error flavour of the same window.
    func testErrorBeforeRegistrationSignalsExactlyOnceAtRegistration() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        await mock.signalError(POSIXError(.ECONNRESET))

        let signals = LockedBox<Int>(0)
        bridge.setInboundReadyHandler { signals.mutate { $0 += 1 } }
        XCTAssertEqual(signals.value, 1, "a pre-registration error must signal at registration")

        let (count, _) = drain(ext)
        XCTAssertLessThan(count, 0, "recv reports the error on the next drain")
        XCTAssertEqual(errno, ECONNRESET)
    }

    // MARK: - Scenario: an outbound send failure is reported by recv, after buffered bytes

    /// WHEN the outbound pump's `transport.send(_:)` fails while inbound bytes are still buffered
    /// THEN C recv drains the bytes first and only then reports the error — the return precedence
    ///      (bytes → EOF → error → would-block) is unchanged by routing the send failure through
    ///      the same inbound entry point.
    func testOutboundSendFailureIsReportedByRecvAfterBufferedBytes() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)
        let ext = bridge.makeExternalTransport()
        defer { _ = ext.close?(ext.userdata) }

        let payload = Data("buffered".utf8)
        await mock.deliver(payload)

        // Closing the mock (not the bridge) makes the next transport.send(_:) throw.
        await mock.close()
        bridge.startOutboundPump()
        let outbound: [UInt8] = [0x01, 0x02]
        _ = outbound.withUnsafeBufferPointer { pointer in
            ext.send!(ext.userdata, pointer.baseAddress, pointer.count)
        }

        // The buffered bytes still come out first.
        let (first, bytes) = drain(ext)
        XCTAssertEqual(first, Int32(payload.count))
        XCTAssertEqual(bytes, payload)

        // Then the send failure surfaces as ECONNRESET.
        let errored = await waitUntil {
            var recvBuf = [UInt8](repeating: 0, count: 64)
            let count: Int32 = recvBuf.withUnsafeMutableBufferPointer { pointer in
                bridge.cRecv(buf: pointer.baseAddress, maxLen: pointer.count)
            }
            return count < 0 && errno == ECONNRESET
        }
        XCTAssertTrue(errored, "a failed outbound send must surface at recv as ECONNRESET")
    }

    // MARK: - Scenario: a delivery after close is ignored

    /// WHEN the bridge has been closed and the transport delivers a chunk, EOF, or an error
    /// THEN nothing is appended, no inbound-ready signal fires, and recv keeps reporting closed
    func testDeliveryAfterCloseIsIgnored() async throws {
        let mock = MockTransport()
        let bridge = try await connectedBridge(to: mock)

        let signals = LockedBox<Int>(0)
        bridge.setInboundReadyHandler { signals.mutate { $0 += 1 } }

        bridge.close()

        // The mock's own close guard would hide the bridge-side behaviour, so deliver straight
        // into the bridge's transport entry point — exactly what an ill-behaved conformer does.
        bridge.deliverInbound(.success(Data("late".utf8)))
        bridge.deliverInbound(.success(Data()))
        bridge.deliverInbound(.failure(POSIXError(.EIO)))

        XCTAssertEqual(signals.value, 0, "no signal may fire once the bridge is closed")
        var recvBuf = [UInt8](repeating: 0, count: 64)
        let count: Int32 = recvBuf.withUnsafeMutableBufferPointer { pointer in
            bridge.cRecv(buf: pointer.baseAddress, maxLen: pointer.count)
        }
        XCTAssertLessThan(count, 0, "recv keeps reporting the closed error")
        XCTAssertEqual(errno, ECONNRESET)
    }

    // MARK: - Scenario: the inbound handler does not retain the bridge

    /// WHEN a bridge has connected a transport (which now holds the bridge's inbound handler)
    /// AND the bridge's last strong reference is released
    /// THEN the bridge is deallocated while the transport still exists
    ///
    /// WHY: bridge → transport → closure → bridge would otherwise be a retain cycle, and the
    /// bridge's lifetime must stay exactly the `userdata` retain that the close trampoline
    /// balances — never dependent on a conformer releasing the closure.
    func testInboundHandlerDoesNotRetainTheBridge() async throws {
        let mock = MockTransport()
        var bridge: TransportBridge? = TransportBridge(transport: mock)
        // `weak var` + separate assignment: `weak let` needs Swift 6.2 (Linux CI is 6.1) and a
        // never-mutated `weak var` warns on 6.2.
        weak var weakBridge: TransportBridge?
        weakBridge = bridge
        try await bridge?.connect(host: "localhost", port: 445)
        XCTAssertNotNil(weakBridge)

        bridge = nil
        XCTAssertNil(weakBridge, "the transport's handler must not keep the bridge alive")

        // The mock still holds the (now weak-captured) closure; invoking it must be harmless.
        await mock.deliver(Data("after dealloc".utf8))
    }
}

#endif // canImport(Network)
