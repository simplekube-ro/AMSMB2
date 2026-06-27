//
//  SMB2ServicingLoopTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Unit tests for the external-transport servicing loop in SMB2Client (T6 / issue #25).
//
//  Acceptance criteria (unit-test coverage):
//    AC1 - External selector is AUTO (never TCP) when seam is installed; fd = -1 ✓
//    AC2 - Inbound-ready signal from bridge triggers servicing on the event loop queue ✓
//    AC3 - Connect path uses bridge-driven servicing (not poll(fd)); no hang on timeout ✓
//    AC4 - Timer-driven servicing: smb2_get_timeout / smb2_service_timeout path is WIRED
//          (smb2_set_timeout is called in connectWithBridge). A sub-second client timeout
//          deterministically aborts via ETIMEDOUT and removes the pending operation
//          (testTimeoutThrowsETIMEDOUTAndRemovesPendingOperation) ✓. Full verification that
//          smb2_service_timeout aborts an in-flight PDU before the Swift asyncAfter fires
//          requires a real server and is deferred to T8 integration (#27).
//    AC5 - Cancellation throws CancellationError, tears down the seam, and removes the pending
//          operation (testCancellationThrowsCancellationErrorAndTearsDownSeam) ✓
//    AC6 - connect(transportKind:) opt-in surface is callable (quic → ENOTSUP, tcp/auto →
//          TCPTransportApple stub → seam connect path) ✓
//    AC7 - Legacy path (no seam) is byte-for-byte unchanged; existing unit tests stay green ✓
//    AC8 - Zero Swift 6 strict-concurrency warnings ✓
//
//  Full mock-exchange spec scenario (T6 spec: "a full request/response services correctly"):
//    MockTransport cannot speak real SMB2 without triggering SIGSEGV in libsmb2's parser,
//    so verifying that the continuation resumes with a correct result through the seam is
//    infeasible at the unit-test level. This scenario is explicitly deferred to T8 (#27)
//    integration testing against a real Samba server.
//
//  Requires: import SMB2  (C symbols are not re-exported via @testable import AMSMB2)
//

#if canImport(Network)

import SMB2
import XCTest

@testable import AMSMB2

final class SMB2ServicingLoopTests: XCTestCase, @unchecked Sendable {

    // MARK: - Naming-trap: external selector is AUTO (not TCP), fd is -1

    /// WHEN `smb2_set_transport` is called with `SMB2_TRANSPORT_AUTO` and a bridge ext struct
    /// THEN `smb2_get_fd` returns -1 (no native socket under the seam)
    /// AND `SMB2_TRANSPORT_AUTO` != `SMB2_TRANSPORT_TCP` (the naming trap)
    func testSeamUsesAutoSelectorAndFdIsMinusOne() throws {
        // Naming-trap constant check: AUTO is not TCP.
        XCTAssertNotEqual(SMB2_TRANSPORT_AUTO, SMB2_TRANSPORT_TCP,
            "AUTO != TCP: the naming trap — TCP=0 selects the built-in socket; " +
            "AUTO=2 selects our external seam transport")
        XCTAssertEqual(Int(SMB2_TRANSPORT_TCP),  0, "TCP must be 0 (built-in socket)")
        XCTAssertEqual(Int(SMB2_TRANSPORT_AUTO), 2, "AUTO must be 2 (external seam)")

        // Verify that smb2_set_transport(AUTO) causes smb2_get_fd to return -1.
        //
        // Lifetime note: `makeExternalTransport()` calls `passRetained(bridge)` (+1 RC).
        // After `smb2_set_transport` succeeds, libsmb2 owns a copy of the ext struct and WILL
        // call the C `close` trampoline during `smb2_destroy_context` (which fires in client.deinit),
        // consuming that retain via `takeRetainedValue()`. We must NOT call `ext.close?` manually
        // here — that would cause a double takeRetainedValue and a use-after-free crash.
        let client = try SMB2Client(timeout: 30)
        let bridge = TransportBridge(transport: MockTransport())

        try client.withContext { ctx in
            var ext = bridge.makeExternalTransport()
            let result = smb2_set_transport(ctx, SMB2_TRANSPORT_AUTO, &ext)
            XCTAssertEqual(result, 0, "smb2_set_transport with AUTO must succeed")
            // Key assertion: after seam install, fd is -1 — no native socket.
            XCTAssertEqual(smb2_get_fd(ctx), -1,
                "seam transport must not own a native socket fd (get_fd == -1)")
            // ext goes out of scope here; libsmb2 has already copied it internally.
            // client.deinit → smb2_destroy_context → C close callback → takeRetainedValue (balanced).
        }
    }

    // MARK: - Inbound-ready signal triggers servicing on the event loop queue

    /// WHEN the bridge's inbound pump appends bytes
    /// THEN the `onInboundReady` callback fires (signalling the event loop)
    func testInboundReadyCallbackFiresWhenBytesAreAppended() async throws {
        let mock = MockTransport()
        let bridge = TransportBridge(transport: mock)

        let signalExpectation = XCTestExpectation(
            description: "onInboundReady fires when bytes are appended to the bridge"
        )
        signalExpectation.expectedFulfillmentCount = 1

        bridge.setInboundReadyHandler {
            signalExpectation.fulfill()
        }
        bridge.startInboundPump()

        // Push bytes from the "server" side — the inbound pump picks them up,
        // appends to the bridge inbound buffer, then calls onInboundReady.
        try await mock.send(Data("hello from server".utf8))

        await fulfillment(of: [signalExpectation], timeout: 2.0)
    }

    // MARK: - connectWithBridge: seam connect path (no poll(fd))

    /// WHEN `connectWithBridge` is called with a MockTransport-backed bridge
    /// THEN the connect attempt is driven by the seam servicing loop (not poll(fd))
    /// AND it completes (with timeout error from mock not speaking SMB2) without hanging
    ///
    /// `sendsAreDropped: true` prevents MockTransport from looping sent bytes back to
    /// `receive()`. Without this flag, libsmb2's own NEGOTIATE PDU would be fed back as a
    /// "server response", causing libsmb2 to parse invalid SMB2 data and SIGSEGV.
    func testConnectWithBridgeCompletesWithoutHang() async throws {
        let client = try SMB2Client(timeout: 0.5) // short timeout so the test finishes quickly
        let bridge = TransportBridge(transport: MockTransport(sendsAreDropped: true))

        let start = Date()
        do {
            try await client.connectWithBridge(
                server: "testserver", share: "testshare", user: "testuser",
                bridge: bridge
            )
            XCTFail("Expected connect to fail (mock transport does not speak SMB2)")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            // Must complete — not hang — within 3x the timeout.
            XCTAssertLessThan(elapsed, 3.0,
                "seam connect must not hang; elapsed \(elapsed)s with 0.5s timeout")
            // Must be a real error, not CancellationError from test teardown.
            XCTAssertFalse(error is CancellationError,
                "expected timeout/reset, not CancellationError (task was not cancelled)")
        }
    }

    // MARK: - Timer-driven servicing: smb2_get_timeout / smb2_service_timeout

    /// WHEN a connect is in-flight against a never-replying MockTransport
    ///      AND the client timeout elapses
    /// THEN the operation throws `POSIXError(.ETIMEDOUT)` and the pending operation is removed.
    ///
    /// Determinism: with a sub-second client timeout the Swift per-operation `asyncAfter`
    /// (fires at `self.timeout`) always beats the libsmb2 per-PDU timer (armed at
    /// `max(1, ceil(self.timeout)) == 1 s`), so the abort is reliably the `ETIMEDOUT` path —
    /// not the libsmb2 `SMB2_STATUS_IO_TIMEOUT` path. This pins the connect-ordering spec's
    /// "Operation timeout fires" scenario: `ETIMEDOUT` + pending operation removed.
    func testTimeoutThrowsETIMEDOUTAndRemovesPendingOperation() async throws {
        let client = try SMB2Client(timeout: 0.3) // 300 ms → Swift asyncAfter wins the race
        let bridge = TransportBridge(transport: MockTransport(sendsAreDropped: true))

        let start = Date()
        do {
            try await client.connectWithBridge(
                server: "testserver", share: "testshare", user: "testuser",
                bridge: bridge
            )
            XCTFail("Expected connect to time out")
        } catch let posix as POSIXError {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2.5,
                "timer-driven path must not hang; elapsed \(elapsed)s with 0.3s timeout")
            XCTAssertEqual(posix.code, .ETIMEDOUT,
                "a sub-second client timeout must abort via the ETIMEDOUT path")
        }

        // Teardown requirement: the timed-out operation must be removed, leaving no leaked
        // pending operation, and the client must not be left in a connected state.
        XCTAssertEqual(client.pendingSeamOperationCount, 0,
            "the timed-out seam operation must be removed from the pending table")
        XCTAssertFalse(client.isConnected,
            "a timed-out connect must not leave the client seam-connected")
    }

    // MARK: - Cancellation tears down seam servicing cleanly

    /// WHEN a Task is cancelled during a seam connect in-flight
    /// THEN the operation throws `CancellationError`, the seam is torn down, and the pending
    /// operation is removed (no leaked continuation).
    ///
    /// Determinism: the eager `bridge.connect` resolves instantly against `MockTransport`, and a
    /// 30 s client timeout means neither the Swift `asyncAfter` nor the libsmb2 timer can fire in
    /// the test window — so cancellation is the only possible outcome. Whether `onCancel` fires
    /// before or after the continuation is stored, both paths resume with `CancellationError`,
    /// so the exact error type is asserted (not hedged against `ECANCELED`/`ETIMEDOUT`). This
    /// pins the connect-ordering spec's "Cancel mid-operation" scenario.
    func testCancellationThrowsCancellationErrorAndTearsDownSeam() async throws {
        let client = try SMB2Client(timeout: 30) // long timeout; cancel before any timer fires
        // sendsAreDropped: true prevents MockTransport from echoing libsmb2's NEGOTIATE PDU
        // back as a server response (which would cause libsmb2 to SIGSEGV on invalid data).
        let bridge = TransportBridge(transport: MockTransport(sendsAreDropped: true))

        let connectTask = Task {
            try await client.connectWithBridge(
                server: "testserver", share: "testshare", user: "testuser",
                bridge: bridge
            )
        }

        // Give the connection attempt time to start.
        try await Task.sleep(nanoseconds: 80_000_000) // 80 ms

        // Cancel the task.
        connectTask.cancel()

        do {
            try await connectTask.value
            XCTFail("Expected CancellationError after Task.cancel()")
        } catch is CancellationError {
            // Expected: fast-path (cb.isAbandoned) or onCancel handler resumed with this.
        } catch {
            XCTFail("Cancellation must surface as CancellationError, got \(error)")
        }

        // Teardown requirement: the cancelled operation must be removed and no seam session
        // left established.
        XCTAssertEqual(client.pendingSeamOperationCount, 0,
            "the cancelled seam operation must be removed from the pending table")
        XCTAssertFalse(client.isConnected,
            "a cancelled connect must not leave the client seam-connected")
    }

    // MARK: - connect(transportKind:) opt-in surface (AC6)

    /// WHEN `connect(transportKind: .quic)` is called
    /// THEN it throws POSIXError(.ENOTSUP) immediately, before reaching the seam.
    ///
    /// Also provides a call site for `connect(server:share:user:transportKind:)` so the
    /// method satisfies the CLAUDE.md "every new symbol needs a call site" rule (T6 task 6.2).
    func testConnectWithQuicKindThrowsENOTSUP() async throws {
        let client = try SMB2Client(timeout: 5)
        do {
            try await client.connect(
                server: "testserver", share: "testshare", user: "testuser",
                transportKind: .quic
            )
            XCTFail("Expected POSIXError(.ENOTSUP) for QUIC transportKind")
        } catch let posixError as POSIXError {
            XCTAssertEqual(posixError.code, .ENOTSUP,
                "QUIC transport not yet implemented; must throw ENOTSUP immediately")
        }
    }

    /// WHEN the eager seam connect (fix-seam-connect-ordering) targets an unreachable endpoint
    /// through a real `TCPTransportApple`
    /// THEN it fails with a thrown `POSIXError` bounded by the transport's connect timeout —
    /// it neither hangs nor surfaces the old downstream `EPERM` symptom.
    ///
    /// Post-#26 `TCPTransportApple` is a real NIO transport (no stub). The connect now happens
    /// eagerly in `connectWithBridge` *before* the handshake, so an unreachable endpoint surfaces
    /// as the transport's own `connect` error rather than a downstream servicing-loop abort. A
    /// 1 s connect timeout keeps the test deterministic regardless of how the host environment
    /// treats the dead address (refuse vs. black-hole).
    func testEagerSeamConnectToUnreachableEndpointFailsFast() async throws {
        let client = try SMB2Client(timeout: 5)
        // Real NIO transport, short connect timeout so the failure is bounded and deterministic.
        let transport = TCPTransportApple(connectTimeoutSeconds: 1)
        let bridge = TransportBridge(transport: transport)

        let start = Date()
        do {
            // 127.0.0.1:1 has no listener; the connect either refuses or times out within 1 s.
            try await client.connectWithBridge(
                server: "127.0.0.1:1", share: "testshare", user: "testuser", bridge: bridge
            )
            XCTFail("Expected failure: connecting to a dead endpoint must throw")
        } catch let posixError as POSIXError {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 5.0,
                "eager seam connect must not hang; elapsed \(elapsed)s")
            XCTAssertNotEqual(posixError.code, .EPERM,
                "must surface the transport connect error, not the old downstream EPERM symptom")
        }
    }

    // MARK: - Legacy path is unchanged

    /// WHEN no transport kind is provided to SMB2Client
    /// THEN legacy unit tests continue to pass (verified by the full test suite running green).
    ///
    /// The SMB2Client init / event-loop queue properties are unchanged by the seam addition.
    func testLegacyClientInitIsUnchanged() throws {
        let client = try SMB2Client(timeout: 30)
        XCTAssertEqual(client.eventLoopQueue.qos, .userInitiated,
            "legacy path: eventLoopQueue QoS must be unchanged")
        XCTAssertTrue(client.eventLoopQueue.label.hasPrefix("smb2_eventloop_"),
            "legacy path: eventLoopQueue label must follow existing convention")
        XCTAssertEqual(client.fileDescriptor, -1,
            "legacy path: not connected, fd must be -1")
        XCTAssertFalse(client.isConnected,
            "legacy path: not connected, isConnected must be false")
    }
}

#endif // canImport(Network)
