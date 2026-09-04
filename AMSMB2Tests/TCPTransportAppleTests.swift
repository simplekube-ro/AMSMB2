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
//    - send before connect → POSIXError(.ENOTCONN)
//    - close() before connect is safe and idempotent
//    - Inbound bytes are pushed to the handler supplied at connect, in arrival order;
//      EOF and errors are delivered once and are terminal; a zero-length read is not EOF;
//      close() delivers nothing and releases the handler closure
//
//  Full send/receive round-trip is validated in T8 (#27) against a real Samba server.
//
//  Guard: Apple-only — TCPTransportApple does not exist on Linux.
//

#if canImport(Network)

import NIOCore
import NIOEmbedded
import Network
import XCTest

@testable import AMSMB2

// MARK: - AsyncGate

/// A latching async gate for deterministic race tests (design D8): `wait()` parks until
/// `open()`; once opened, later waits return immediately (so a stray extra entry can never
/// hang the suite — it is caught by the `entryCount` assertion instead). Entry counting is
/// the single-ownership assertion: exactly one production path may reach a gated point.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var entries = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Number of times `wait()` has been entered (open or parked).
    var entryCount: Int {
        lock.withLock { entries }
    }

    var hasEntered: Bool {
        entryCount > 0
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked: Bool = lock.withLock {
                entries += 1
                guard !opened else { return false }
                waiters.append(continuation)
                return true
            }
            if !parked {
                continuation.resume(returning: ())
            }
        }
    }

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let parked = waiters
            waiters = []
            return parked
        }
        for waiter in toResume {
            waiter.resume(returning: ())
        }
    }
}

final class TCPTransportAppleTests: XCTestCase, @unchecked Sendable {

    // MARK: - Helpers (deterministic race tests)

    /// Polls `predicate` (state guarded by the doubles' locks) until true or the bound
    /// elapses — synchronization on observable state, never a wall-clock proof (mirrors
    /// `QUICTransportAppleTests.waitUntil`).
    private func waitUntil(
        _ predicate: @escaping () -> Bool, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2000 {
            if predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
        XCTFail("timed out waiting: \(message)", file: file, line: line)
    }

    /// An empty reference type whose deallocation proves the handler closure was released.
    final class HandlerReleaseProbe: @unchecked Sendable {}

    /// Builds a receiver that both records deliveries and retains `probe`, without leaving a
    /// strong reference to `probe` in the caller's frame.
    private static func makeRetainingHandler(
        _ probe: HandlerReleaseProbe, recorder: InboundRecorder
    ) -> InboundReceiver {
        let record = recorder.handler
        return { result in
            _ = probe
            record(result)
        }
    }

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
        let recorder = InboundRecorder()
        let transport = TCPTransportApple(connectTimeoutSeconds: 2)
        defer { Task { await transport.close() } }

        do {
            // Port 1 on loopback is almost universally refused or unreachable on macOS.
            try await transport.connect(host: "127.0.0.1", port: 1, onReceive: recorder.handler)
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

    // MARK: - send before connect

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
        let recorder = InboundRecorder()
        let transport = TCPTransportApple(connectTimeoutSeconds: 10)
        defer { Task { await transport.close() } }

        let start = Date()
        let task: Task<Void, any Error> = Task {
            try await transport.connect(host: "192.0.2.1", port: 445, onReceive: recorder.handler)
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
        let recorder = InboundRecorder()
        let transport = TCPTransportApple(connectTimeoutSeconds: 3)
        defer { Task { await transport.close() } }

        let firstTask: Task<Void, any Error> = Task {
            try await transport.connect(host: "192.0.2.1", port: 445, onReceive: recorder.handler)
        }
        // Let the first connect take the reservation and get in flight.
        try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms

        let start = Date()
        do {
            try await transport.connect(host: "192.0.2.1", port: 445, onReceive: recorder.handler)
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
    /// usable for send() — the rejected call must not replace or leak the live channel, and the
    /// FIRST call's receiver, not the rejected call's, keeps receiving.
    ///
    /// WHY the second recorder: making the handler a `connect` parameter means every rejected
    /// call carries one too. Installing it before the one-shot reservation succeeded would
    /// silently redirect a live connection's inbound bytes to a handler nobody is reading.
    func testConnectAfterConnectedThrowsEISCONNAndKeepsChannelUsable() async throws {
        let recorder = InboundRecorder()
        let (listener, retained, port) = try await startLocalListener()
        defer {
            listener.cancel()
            retained.value.forEach { $0.cancel() }
        }

        let transport = TCPTransportApple(connectTimeoutSeconds: 5)
        defer { Task { await transport.close() } }
        try await transport.connect(host: "127.0.0.1", port: port, onReceive: recorder.handler)

        let rejectedRecorder = InboundRecorder()
        do {
            try await transport.connect(host: "127.0.0.1", port: port, onReceive: rejectedRecorder.handler)
            XCTFail("connect after an established connection must be rejected")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EISCONN, "connect after connected must fail with EISCONN")
        } catch {
            XCTFail("expected POSIXError(.EISCONN), got \(type(of: error)): \(error)")
        }

        // The original channel must still be usable — the rejected call touched nothing.
        try await transport.send(Data("still-usable".utf8))

        // …and the first call's receiver is still the one being fed.
        await waitUntil({ retained.value.count == 1 }, "listener accepted the connection")
        let accepted = try XCTUnwrap(retained.value.first)
        accepted.send(content: Data("after-rejection".utf8), completion: .idempotent)
        let receivedAfterRejection = await recorder.waitForDeliveries(count: 1)
        XCTAssertTrue(
            receivedAfterRejection,
            "the first call's handler keeps receiving after a rejected repeat connect"
        )
        XCTAssertEqual(recorder.deliveredData, [Data("after-rejection".utf8)])
        XCTAssertEqual(rejectedRecorder.deliveryCount, 0, "the rejected call's handler is never invoked")
    }

    /// WHEN the first connect attempt failed and connect() is called again
    /// THEN the call fails promptly with EALREADY — retry after failure is unsupported
    /// (one instance per connection lifetime; build a fresh transport instead). The
    /// elapsed-time bound proves no second network attempt ran.
    func testConnectAfterFailedAttemptThrowsEALREADYPromptly() async {
        let recorder = InboundRecorder()
        let transport = TCPTransportApple(connectTimeoutSeconds: 2)
        defer { Task { await transport.close() } }

        do {
            // Refused-port pattern.
            try await transport.connect(host: "127.0.0.1", port: 1, onReceive: recorder.handler)
            XCTFail("connect to a refused port must throw")
        } catch {
            // Expected — any network-layer failure consumes the one-shot attempt.
        }

        let start = Date()
        do {
            try await transport.connect(host: "127.0.0.1", port: 1, onReceive: recorder.handler)
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
        let recorder = InboundRecorder()
        let transport = TCPTransportApple(connectTimeoutSeconds: 2)
        do {
            try await transport.connect(host: "127.0.0.1", port: 1, onReceive: recorder.handler)
            XCTFail("connect to a refused port must throw")
        } catch {
            // Expected.
        }
        await transport.close()

        do {
            try await transport.connect(host: "127.0.0.1", port: 445, onReceive: recorder.handler)
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

    // MARK: - Publication race and owned close lifecycle (design D5–D8)

    /// Finding 1 + finding 2, close flavor: a successful bootstrap is held at exactly the
    /// pre-publication point (D8 gate) and `close()` wins the race.
    ///
    /// WHEN `close()` completes its claim while the connect is gated immediately before the
    /// publication critical section
    /// THEN `connect` must NOT return success (it throws the closed contract's `ENOTCONN`),
    /// the channel must not be (or remain) installed, the never-published channel is closed
    /// exactly once, and `close()` returns only after the gated connect tail has fully
    /// drained — proven by the close caller staying parked while the gate holds.
    func testCloseWinningPrePublicationRaceAbortsConnectAndCloseWaitsForConnectTail() async throws {
        let recorder = InboundRecorder()
        let (listener, retained, port) = try await startLocalListener()
        defer {
            listener.cancel()
            retained.value.forEach { $0.cancel() }
        }

        let transport = TCPTransportApple(connectTimeoutSeconds: 5)
        let gate = AsyncGate()
        transport.connectPublicationGate = { await gate.wait() }

        let connectTask: Task<Void, any Error> = Task {
            try await transport.connect(host: "127.0.0.1", port: port, onReceive: recorder.handler)
        }
        await waitUntil({ gate.hasEntered }, "connect parked immediately before publication")

        let closeDone = TestFlag()
        let closeTask: Task<Void, Never> = Task {
            await transport.close()
            closeDone.set()
        }
        // The owned close lifecycle must park the owner on the still-gated connect tail —
        // returning here would mean close() finished while the tail could still publish.
        await waitUntil(
            { transport.pendingCloseWaiterCount == 1 },
            "close parked awaiting the gated connect tail"
        )
        XCTAssertFalse(
            closeDone.isSet,
            "close() must not return while the pre-publication connect tail is still gated"
        )

        gate.open()
        do {
            try await connectTask.value
            XCTFail("connect must not return success after close won the pre-publication race")
        } catch let posix as POSIXError {
            XCTAssertEqual(
                posix.code, .ENOTCONN,
                "a close-won publication must surface the conformer's closed contract"
            )
        } catch {
            XCTFail("expected POSIXError(.ENOTCONN), got \(type(of: error)): \(error)")
        }
        await closeTask.value
        XCTAssertFalse(
            transport.hasInstalledChannel,
            "the closed channel must never be installed after close() returned"
        )
        XCTAssertEqual(
            transport.abortedConnectChannelCloseCount, 1,
            "the never-published channel must be closed exactly once"
        )
        // A connect that throws must never invoke its handler. The bootstrap DID succeed here,
        // so the never-published channel is live with the forwarding handler in its pipeline —
        // closing it produces a channelInactive that must not reach this call's receiver.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            recorder.deliveryCount, 0,
            "a connect that throws must never deliver — not even the EOF its own abort produces"
        )
    }

    /// Finding 1, cancellation flavor: the bootstrap succeeded, the cancellation handler has
    /// already exited, and the task is cancelled while the connect is gated immediately
    /// before publication — the pure post-handler cancellation window.
    ///
    /// WHEN task cancellation wins the race immediately before channel publication
    /// THEN `connect` throws `POSIXError(.ECANCELED)`, no channel remains installed, and the
    /// never-published channel's teardown occurs exactly once.
    func testCancellationWinningPrePublicationRaceThrowsECANCELEDWithoutInstalling() async throws {
        let recorder = InboundRecorder()
        let (listener, retained, port) = try await startLocalListener()
        defer {
            listener.cancel()
            retained.value.forEach { $0.cancel() }
        }

        let transport = TCPTransportApple(connectTimeoutSeconds: 5)
        let gate = AsyncGate()
        transport.connectPublicationGate = { await gate.wait() }

        let connectTask: Task<Void, any Error> = Task {
            try await transport.connect(host: "127.0.0.1", port: port, onReceive: recorder.handler)
        }
        await waitUntil({ gate.hasEntered }, "connect parked immediately before publication")

        // cancel() marks the task synchronously, so the cancellation is deterministically
        // observable by the publication claim before the gate releases it.
        connectTask.cancel()
        gate.open()

        do {
            try await connectTask.value
            XCTFail("connect must not return success after cancellation won the pre-publication race")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ECANCELED, "cancellation-won publication must throw ECANCELED")
        } catch {
            XCTFail("expected POSIXError(.ECANCELED), got \(type(of: error)): \(error)")
        }
        XCTAssertFalse(
            transport.hasInstalledChannel,
            "no channel may remain installed after a cancelled connect"
        )
        XCTAssertEqual(
            transport.abortedConnectChannelCloseCount, 1,
            "teardown of the never-published channel must occur exactly once"
        )
        // Same contract on the cancellation flavour: the aborted channel's teardown must not
        // surface as a graceful-EOF delivery to a connect that threw ECANCELED.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            recorder.deliveryCount, 0,
            "a cancelled connect must never deliver — not even the EOF its own abort produces"
        )

        await transport.close()
    }

    /// Finding 2: the owned close lifecycle `open → closing(waiters) → closed`.
    ///
    /// WHEN two `close()` calls race while the owner's teardown is held at the D8 gate
    /// THEN both callers remain suspended while the gate holds, exactly one caller entered
    /// the teardown, releasing the gate completes that single teardown and resumes both, and
    /// a later close after full completion returns without a second teardown entry.
    func testConcurrentClosesShareOneOwnedTeardownAndLaterCloseIsTerminalNoOp() async throws {
        let recorder = InboundRecorder()
        let (listener, retained, port) = try await startLocalListener()
        defer {
            listener.cancel()
            retained.value.forEach { $0.cancel() }
        }

        let transport = TCPTransportApple(connectTimeoutSeconds: 5)
        try await transport.connect(host: "127.0.0.1", port: port, onReceive: recorder.handler)

        let gate = AsyncGate()
        transport.closeTeardownGate = { await gate.wait() }

        let firstDone = TestFlag()
        let secondDone = TestFlag()
        let firstClose: Task<Void, Never> = Task {
            await transport.close()
            firstDone.set()
        }
        let secondClose: Task<Void, Never> = Task {
            await transport.close()
            secondDone.set()
        }

        await waitUntil({ gate.hasEntered }, "the owning close reached the gated teardown")
        await waitUntil(
            { transport.pendingCloseWaiterCount == 1 },
            "the concurrent close parked behind the owner"
        )
        XCTAssertEqual(gate.entryCount, 1, "teardown must be entered by exactly one owner")
        XCTAssertFalse(firstDone.isSet, "the owning close must not return while teardown is gated")
        XCTAssertFalse(secondDone.isSet, "the concurrent close must not return before teardown completes")

        gate.open()
        await firstClose.value
        await secondClose.value
        XCTAssertTrue(firstDone.isSet && secondDone.isSet, "both callers complete after the teardown")
        XCTAssertEqual(gate.entryCount, 1, "one owned teardown serves both close callers")

        await transport.close() // after full completion — the terminal no-op.
        XCTAssertEqual(
            gate.entryCount, 1,
            "a close after a fully-completed close must not run a second teardown"
        )
        XCTAssertFalse(transport.hasInstalledChannel)
    }

    // MARK: - Pushed inbound delivery (design D3)

    /// WHEN the peer writes twice, each write landing as its own channel read
    /// THEN the handler is invoked once per arrival, in order — the transport neither buffers
    ///      nor coalesces (the second write is only made after the first delivery landed, so a
    ///      coalescing transport would still show two deliveries only if it delivers per read).
    func testInboundBytesAreDeliveredAsTheyArriveInOrder() async throws {
        let recorder = InboundRecorder()
        let (listener, retained, port) = try await startLocalListener()
        defer {
            listener.cancel()
            retained.value.forEach { $0.cancel() }
        }

        let transport = TCPTransportApple(connectTimeoutSeconds: 5)
        defer { Task { await transport.close() } }
        try await transport.connect(host: "127.0.0.1", port: port, onReceive: recorder.handler)

        await waitUntil({ retained.value.count == 1 }, "listener accepted the connection")
        let accepted = try XCTUnwrap(retained.value.first)

        let first = Data("first-chunk".utf8)
        accepted.send(content: first, completion: .idempotent)
        let gotFirst = await recorder.waitForDeliveries(count: 1)
        XCTAssertTrue(gotFirst, "the first chunk must be delivered")

        let second = Data("second-chunk".utf8)
        accepted.send(content: second, completion: .idempotent)
        let gotSecond = await recorder.waitForDeliveries(count: 2)
        XCTAssertTrue(gotSecond, "the second chunk must be delivered")

        XCTAssertEqual(
            recorder.deliveredData, [first, second],
            "each arrival is its own delivery, in order"
        )
    }

    /// WHEN the peer closes the connection
    /// THEN the handler is invoked exactly once with empty `Data` (graceful EOF) and never again
    func testPeerCloseDeliversExactlyOneEmptyDataAndNothingAfter() async throws {
        let recorder = InboundRecorder()
        let (listener, retained, port) = try await startLocalListener()
        defer {
            listener.cancel()
            retained.value.forEach { $0.cancel() }
        }

        let transport = TCPTransportApple(connectTimeoutSeconds: 5)
        defer { Task { await transport.close() } }
        try await transport.connect(host: "127.0.0.1", port: port, onReceive: recorder.handler)

        await waitUntil({ retained.value.count == 1 }, "listener accepted the connection")
        retained.value.forEach { $0.cancel() }

        let gotEOF = await recorder.waitForDeliveries(count: 1)
        XCTAssertTrue(gotEOF, "peer close must deliver EOF")
        XCTAssertEqual(recorder.deliveredData, [Data()], "graceful EOF is one empty Data delivery")

        // Terminal: the channel's own teardown events that follow must add nothing. Settling
        // briefly gives any spurious later delivery a chance to show up.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recorder.deliveryCount, 1, "EOF is terminal — nothing follows it")
    }

    /// WHEN `close()` is called while the channel is live
    /// THEN the handler receives no delivery for the teardown the close itself produces, and the
    ///      handler closure is released once `close()` completes.
    ///
    /// WHY: the bridge must see the identical "silent teardown" it saw when its pull loop was
    /// cancelled before it could observe the close EOF — and a conformer that kept the closure
    /// would keep a dead bridge's handler alive.
    func testCloseMakesNoDeliveryAndReleasesTheHandlerClosure() async throws {
        let recorder = InboundRecorder()
        let (listener, retained, port) = try await startLocalListener()
        defer {
            listener.cancel()
            retained.value.forEach { $0.cancel() }
        }

        let transport = TCPTransportApple(connectTimeoutSeconds: 5)
        var probe: HandlerReleaseProbe? = HandlerReleaseProbe()
        // `weak var` + separate assignment: `weak let` needs Swift 6.2 (Linux CI is 6.1) and a
        // never-mutated `weak var` warns on 6.2.
        weak var weakProbe: HandlerReleaseProbe?
        weakProbe = probe
        try await transport.connect(
            host: "127.0.0.1", port: port,
            onReceive: Self.makeRetainingHandler(try XCTUnwrap(probe), recorder: recorder)
        )
        probe = nil
        XCTAssertNotNil(weakProbe, "the transport holds the handler closure while connected")

        await waitUntil({ retained.value.count == 1 }, "listener accepted the connection")
        await transport.close()

        XCTAssertEqual(recorder.deliveryCount, 0, "close() must produce no inbound delivery")
        XCTAssertNil(weakProbe, "the handler closure is released once close() completes")
    }

    /// WHEN the channel raises an error
    /// THEN the handler is invoked exactly once with a `POSIXError` failure, and delivery is
    ///      terminal afterwards.
    ///
    /// Driven through an `EmbeddedChannel` so the error is injected deterministically — a real
    /// socket cannot be made to raise a chosen `ChannelError` on demand.
    func testChannelErrorIsDeliveredOnceAsPOSIXErrorAndIsTerminal() throws {
        let recorder = InboundRecorder()
        let handler = InboundForwardingHandler()
        handler.install(recorder.handler)
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(handler).wait()

        channel.pipeline.fireErrorCaught(ChannelError.ioOnClosedChannel)

        XCTAssertEqual(recorder.deliveryCount, 1, "a channel error is delivered exactly once")
        XCTAssertEqual(
            recorder.deliveredErrors.map(\.code), [.ENOTCONN],
            "NIO/NW errors are mapped to POSIXError before they cross the seam"
        )

        // Terminal: the channelInactive the error's own close produces must add nothing.
        channel.pipeline.fireChannelInactive()
        XCTAssertEqual(recorder.deliveryCount, 1, "an error delivery is terminal")
        _ = try? channel.finish()
    }

    /// WHEN the channel delivers a read with no readable bytes while the connection is open
    /// THEN the handler is not invoked and a later non-empty read is delivered normally.
    ///
    /// WHY this guard exists: empty `Data` at the seam *means* graceful EOF, so forwarding a
    /// zero-length read would tear the connection down spuriously. The guard sits before the
    /// `TransportRead` signpost too, which is what makes the read↔chunk pairing 1:1.
    func testZeroLengthReadIsNotDeliveredAndDoesNotEndTheStream() throws {
        let recorder = InboundRecorder()
        let handler = InboundForwardingHandler()
        handler.install(recorder.handler)
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(handler).wait()

        let empty = channel.allocator.buffer(capacity: 0)
        try channel.writeInbound(empty)
        XCTAssertEqual(recorder.deliveryCount, 0, "a zero-length read is not a delivery")

        var payload = channel.allocator.buffer(capacity: 4)
        payload.writeBytes([0x01, 0x02, 0x03, 0x04])
        try channel.writeInbound(payload)
        XCTAssertEqual(
            recorder.deliveredData, [Data([0x01, 0x02, 0x03, 0x04])],
            "the stream is unaffected: the next non-empty read is delivered normally"
        )
        _ = try? channel.finish()
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
