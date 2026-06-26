//
//  TCPTransportAppleTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Unit tests for TCPTransportApple (T7 / issue #26).
//
//  What is tested here (no server required):
//    - Compile-time conformance to SMBTransport
//    - Connect failure to a refused port → POSIXError
//    - send/receive before connect → POSIXError(.ENOTCONN)
//    - close() before connect is safe and idempotent
//    - receive() cancellation terminates cleanly (no hang)
//
//  Full send/receive round-trip and inbound-buffering drain are validated in
//  T8 (#27) against a real Samba server.
//
//  Guard: Apple-only — TCPTransportApple does not exist on Linux.
//

#if canImport(Network)

import XCTest

@testable import AMSMB2

final class TCPTransportAppleTests: XCTestCase, @unchecked Sendable {

    // MARK: - Compile-time conformance

    /// WHEN TCPTransportApple is assigned to an SMBTransport variable
    /// THEN the code compiles — proving SMBTransport conformance.
    func testConformsToSMBTransport() {
        let transport: any SMBTransport = TCPTransportApple()
        _ = transport
    }

    // MARK: - Connect failure → POSIXError

    /// WHEN connect is called with a port that is definitely refused on localhost
    /// THEN it throws a POSIXError (not a raw NWError or ChannelError).
    ///
    /// Uses a 2-second connect timeout so the test completes quickly: NIOTransportServices
    /// (Network.framework) may retry loopback connections before giving up, so we cap the
    /// wait rather than relying on instant ECONNREFUSED.
    func testConnectToRefusedPortThrowsPOSIXError() async {
        let transport = TCPTransportApple(connectTimeoutSeconds: 2)
        defer { Task { await transport.close() } }

        do {
            // Port 1 on loopback is almost universally refused or unreachable on macOS.
            try await transport.connect(host: "127.0.0.1", port: 1)
            XCTFail("Expected connect to throw on refused port")
        } catch let posixError as POSIXError {
            // ECONNREFUSED is canonical; ETIMEDOUT is expected when NIOTS retries up to the
            // bootstrap timeout; ENETUNREACH / EADDRNOTAVAIL may also appear on some hosts.
            XCTAssertTrue(
                [.ECONNREFUSED, .ENETUNREACH, .EADDRNOTAVAIL, .ETIMEDOUT].contains(posixError.code),
                "Expected a network-layer POSIXError, got \(posixError.code)"
            )
        } catch {
            XCTFail("Expected POSIXError from connect failure, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - send / receive before connect

    /// WHEN send is called before a successful connect
    /// THEN it throws POSIXError(.ENOTCONN).
    func testSendBeforeConnectThrowsENOTCONN() async {
        let transport = TCPTransportApple()
        defer { Task { await transport.close() } }

        do {
            try await transport.send(Data("hello".utf8))
            XCTFail("Expected send to throw when not connected")
        } catch let posixError as POSIXError {
            XCTAssertEqual(posixError.code, .ENOTCONN,
                "send before connect must throw ENOTCONN, got \(posixError.code)")
        } catch {
            XCTFail("Expected POSIXError(.ENOTCONN), got \(type(of: error)): \(error)")
        }
    }

    /// WHEN receive is called before a successful connect
    /// THEN it throws POSIXError(.ENOTCONN).
    func testReceiveBeforeConnectThrowsENOTCONN() async {
        let transport = TCPTransportApple()
        defer { Task { await transport.close() } }

        do {
            _ = try await transport.receive()
            XCTFail("Expected receive to throw when not connected")
        } catch let posixError as POSIXError {
            XCTAssertEqual(posixError.code, .ENOTCONN,
                "receive before connect must throw ENOTCONN, got \(posixError.code)")
        } catch {
            XCTFail("Expected POSIXError(.ENOTCONN), got \(type(of: error)): \(error)")
        }
    }

    // MARK: - close() safety

    /// WHEN close() is called without a prior successful connect
    /// THEN it does not crash or hang.
    func testCloseBeforeConnectIsSafe() async {
        let transport = TCPTransportApple()
        await transport.close()
        // If we reach here, close() did not crash.
    }

    /// WHEN close() is called twice on the same transport
    /// THEN the second call is a no-op and does not crash.
    func testCloseIsIdempotent() async {
        let transport = TCPTransportApple()
        await transport.close()
        await transport.close() // Must not crash or hang.
    }

    // MARK: - receive() cancellation

    /// WHEN receive() is suspended waiting for data and the enclosing Task is cancelled
    /// THEN receive() terminates promptly (no hang) with an appropriate error.
    ///
    /// NOTE: This test exits via the `_channel == nil` guard (transport not connected)
    /// and validates the pre-connect ENOTCONN fast-path. The `InboundBufferingHandler`
    /// onCancel path is covered by `testInboundHandlerReceiveCancellationExercisesOnCancelPath`.
    func testReceiveCancellationDoesNotHang() async {
        let transport = TCPTransportApple()
        defer { Task { await transport.close() } }

        let task: Task<Data, any Error> = Task {
            try await transport.receive()
        }

        // Give the task a moment to enter receive(), then cancel it.
        try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected task to throw after cancellation")
        } catch is CancellationError {
            // Expected — receive() propagated cancellation.
        } catch let posixError as POSIXError {
            // Also acceptable: ENOTCONN (not yet connected) or ECANCELED.
            XCTAssertTrue(
                [.ENOTCONN, .ECANCELED].contains(posixError.code),
                "Unexpected POSIXError code: \(posixError.code)"
            )
        } catch {
            XCTFail("Expected CancellationError or POSIXError, got \(type(of: error)): \(error)")
        }
    }

    /// Directly exercises the `InboundBufferingHandler.receive()` onCancel path.
    ///
    /// The handler is created standalone (not attached to a NIO channel) so no
    /// NIO event-loop callbacks will fire. `receive()` suspends waiting for data
    /// and the Task is then cancelled, which should trigger the `onCancel` handler
    /// and promptly resume the continuation with `CancellationError`.
    ///
    /// This validates the documented-deferred race guard: `Task.isCancelled` is
    /// checked inside the lock before storing the continuation, and `onCancel` drains
    /// the waiting continuation when it fires concurrently.
    func testInboundHandlerReceiveCancellationExercisesOnCancelPath() async throws {
        let handler = InboundBufferingHandler()

        // Spawn a task that will suspend inside handler.receive() with no data available.
        let task: Task<Data, any Error> = Task {
            try await handler.receive()
        }

        // Give the task time to store the waiting continuation.
        try await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected task to throw CancellationError after cancellation")
        } catch is CancellationError {
            // Expected: onCancel fired and resumed the continuation with CancellationError.
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Sendable

    /// WHEN a TCPTransportApple is captured across an isolation boundary
    /// THEN it compiles — proving Sendable conformance.
    func testIsSendable() async {
        let transport = TCPTransportApple()
        let echoed = await Task.detached { transport }.value
        defer { Task { await echoed.close() } }
        // Compile proves Sendable; echoed == transport (same instance).
        XCTAssert(echoed === transport)
    }
}

#endif // canImport(Network)
