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

import Network
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

    /// WHEN a connect is still pending (a black-holed endpoint that neither accepts nor refuses)
    /// and the enclosing Task is cancelled
    /// THEN the connect aborts promptly — well before `connectTimeoutSeconds` — rather than
    /// blocking until the connect timeout expires.
    ///
    /// Regression guard for the `onCancel`-only-fires-`whenSuccess` bug: previously the cancel
    /// handler closed the channel only *after* a successful connect, so a pending connect could
    /// not be aborted and waited the full timeout. The fix captures the channel in the
    /// `channelInitializer` (which runs before connect completes) so cancellation can close it.
    ///
    /// `192.0.2.1` is TEST-NET-1 (RFC 5737) — reserved and non-routable, so the connect stays
    /// pending. A generous 10 s connect timeout means an un-aborted connect would block ~10 s;
    /// asserting completion under 5 s proves cancellation aborted the in-flight connect. On a
    /// host that fast-fails the address the test still passes (it just doesn't exercise the
    /// pending-cancel path), so it is green everywhere but red on a true regression.
    func testConnectCancellationAbortsPendingConnectPromptly() async {
        let transport = TCPTransportApple(connectTimeoutSeconds: 10)
        defer { Task { await transport.close() } }

        let start = Date()
        let task: Task<Void, any Error> = Task {
            try await transport.connect(host: "192.0.2.1", port: 445)
        }

        // Let the connect get in-flight, then cancel while it is still pending.
        try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected connect to a black-holed endpoint to throw on cancellation")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(
                elapsed, 5.0,
                "cancellation must abort the pending connect promptly, not wait for the "
                    + "10 s connect timeout; elapsed \(elapsed)s"
            )
            // When cancellation wins the race the mapped error is ECANCELED; a host that
            // fast-fails the reserved address may surface a different network POSIXError, which
            // is also acceptable as long as the timing assertion above holds.
            if let posix = error as? POSIXError {
                XCTAssertNotEqual(
                    posix.code, .ETIMEDOUT,
                    "a prompt cancel must not surface as the connect-timeout error"
                )
            }
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

    // MARK: - One-shot connect ownership (mirrors QUICTransportApple)

    /// Starts a real TCP listener on an ephemeral 127.0.0.1 port and retains accepted
    /// connections so the transport's channel stays alive for the duration of a test.
    /// Bounded: if the listener never becomes ready within 5 s the continuation throws.
    private func startLocalListener() async throws -> (NWListener, LockedBox<[NWConnection]>, Int) {
        let listener = try NWListener(using: .tcp, on: .any)
        let retained = LockedBox<[NWConnection]>([])
        listener.newConnectionHandler = { connection in
            retained.mutate { $0.append(connection) }
            connection.start(queue: DispatchQueue(label: "test.tcp.listener.connection"))
        }
        let queue = DispatchQueue(label: "test.tcp.listener")
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedBox<Bool>(false)
            let resumeOnce: @Sendable (Result<Int, any Error>) -> Void = { result in
                var first = false
                resumed.mutate { alreadyResumed in
                    if !alreadyResumed {
                        alreadyResumed = true
                        first = true
                    }
                }
                guard first else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(Int(listener.port?.rawValue ?? 0)))
                case .failed(let error):
                    resumeOnce(.failure(error))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 5) {
                resumeOnce(.failure(POSIXError(.ETIMEDOUT, description: "listener never became ready")))
            }
            listener.start(queue: queue)
        }
        XCTAssertNotEqual(port, 0, "listener must report a real ephemeral port")
        return (listener, retained, port)
    }

    /// WHEN a second connect() races a first call whose attempt is still in flight
    /// THEN the second call fails promptly with EALREADY (no second bootstrap, bounded well
    /// under the connect timeout) and the owning attempt proceeds unaffected.
    ///
    /// The first connect targets TEST-NET-1 (the file's established pending-connect pattern).
    /// On hosts that fast-fail the reserved address, the first attempt has already consumed
    /// the one shot as `.failed` — which also maps to EALREADY, so the assertion holds in
    /// both environments (which is why in-flight and after-failure share an error code).
    func testSecondConnectWhileAttemptInFlightThrowsEALREADYPromptly() async {
        let transport = TCPTransportApple(connectTimeoutSeconds: 3)
        defer { Task { await transport.close() } }

        let firstTask: Task<Void, any Error> = Task {
            try await transport.connect(host: "192.0.2.1", port: 445)
        }
        // Let the first connect take the reservation and get in flight.
        try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms

        let start = Date()
        do {
            try await transport.connect(host: "192.0.2.1", port: 445)
            XCTFail("second connect must be rejected, not attempted")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EALREADY, "second connect must fail with EALREADY")
        } catch {
            XCTFail("expected POSIXError(.EALREADY), got \(type(of: error)): \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 1.5,
            "the rejection must be prompt — a slow failure means a second bootstrap ran"
        )

        firstTask.cancel()
        do {
            try await firstTask.value
            XCTFail("first connect to a black-holed endpoint must throw")
        } catch {
            // Any error is fine (ECANCELED, or a fast-fail network error) — the point is the
            // owning attempt completed on its own terms, unaffected by the rejected call.
        }
    }

    /// WHEN connect() is called after a previous call connected successfully
    /// THEN it fails promptly with EISCONN and the established channel remains installed and
    /// usable for send() — the rejected call must not replace or leak the live channel.
    func testConnectAfterConnectedThrowsEISCONNAndKeepsChannelUsable() async throws {
        let (listener, retained, port) = try await startLocalListener()
        defer {
            listener.cancel()
            retained.value.forEach { $0.cancel() }
        }

        let transport = TCPTransportApple(connectTimeoutSeconds: 5)
        defer { Task { await transport.close() } }
        try await transport.connect(host: "127.0.0.1", port: port)

        do {
            try await transport.connect(host: "127.0.0.1", port: port)
            XCTFail("connect after an established connection must be rejected")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EISCONN, "connect after connected must fail with EISCONN")
        } catch {
            XCTFail("expected POSIXError(.EISCONN), got \(type(of: error)): \(error)")
        }

        // The original channel must still be usable — the rejected call touched nothing.
        try await transport.send(Data("still-usable".utf8))
    }

    /// WHEN the first connect attempt failed and connect() is called again
    /// THEN the call fails promptly with EALREADY — retry after failure is unsupported
    /// (one instance per connection lifetime; build a fresh transport instead). The
    /// elapsed-time bound proves no second network attempt ran.
    func testConnectAfterFailedAttemptThrowsEALREADYPromptly() async {
        let transport = TCPTransportApple(connectTimeoutSeconds: 2)
        defer { Task { await transport.close() } }

        do {
            try await transport.connect(host: "127.0.0.1", port: 1) // refused-port pattern.
            XCTFail("connect to a refused port must throw")
        } catch {
            // Expected — any network-layer failure consumes the one-shot attempt.
        }

        let start = Date()
        do {
            try await transport.connect(host: "127.0.0.1", port: 1)
            XCTFail("retry after a failed attempt must be rejected")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EALREADY, "retry after failure must fail with EALREADY")
        } catch {
            XCTFail("expected POSIXError(.EALREADY), got \(type(of: error)): \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 1.0,
            "the rejection must be prompt — a slow failure means a second bootstrap ran"
        )
    }

    /// WHEN connect() is called after close(), even when an attempt had already failed
    /// THEN it throws ENOTCONN — the conformer's existing closed-transport contract takes
    /// precedence over the one-shot attempt state. (Contract-preservation guard: this
    /// passes before and after the one-shot change; it pins the error-precedence order.)
    func testConnectAfterCloseThrowsENOTCONNEvenAfterFailedAttempt() async {
        let transport = TCPTransportApple(connectTimeoutSeconds: 2)
        do {
            try await transport.connect(host: "127.0.0.1", port: 1)
            XCTFail("connect to a refused port must throw")
        } catch {
            // Expected.
        }
        await transport.close()

        do {
            try await transport.connect(host: "127.0.0.1", port: 445)
            XCTFail("connect after close must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(
                posix.code, .ENOTCONN,
                "closed contract wins over attempt state: expected ENOTCONN, got \(posix.code)"
            )
        } catch {
            XCTFail("expected POSIXError(.ENOTCONN), got \(type(of: error)): \(error)")
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
