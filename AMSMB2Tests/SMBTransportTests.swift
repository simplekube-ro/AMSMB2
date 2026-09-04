//
//  SMBTransportTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Unit tests for the SMBTransport seam (T4 / issue #23, push-converted by #45).
//  Acceptance criteria:
//    - SMBTransport + SMBTransportKind compile and are public API
//    - MockTransport pushes injected inbound chunks, graceful EOF and errors to the
//      handler supplied at connect, records sent bytes, and surfaces connect failure —
//      with no server and no libsmb2 dependency
//    - Zero Swift 6 strict-concurrency warnings
//

import XCTest

@testable import AMSMB2

final class SMBTransportTests: XCTestCase, @unchecked Sendable {

    // MARK: - SMBTransportKind

    /// Verifies the three expected cases exist.
    /// A compile failure here means a case is missing.
    func testSMBTransportKindCasesExist() {
        let tcp = SMBTransportKind.tcp
        let quic = SMBTransportKind.quic
        let automatic = SMBTransportKind.automatic
        XCTAssertNotEqual(tcp, quic)
        XCTAssertNotEqual(quic, automatic)
        XCTAssertNotEqual(tcp, automatic)
    }

    /// Verifies Sendable conformance by crossing an isolation boundary.
    func testSMBTransportKindIsSendable() async {
        let kind = SMBTransportKind.automatic
        // Crossing into a detached Task exercises the Sendable requirement.
        let echoed = await Task.detached { kind }.value
        XCTAssertEqual(echoed, SMBTransportKind.automatic)
    }

    // MARK: - MockTransport: inbound push

    /// Scenario: Mock delivers injected inbound bytes.
    ///
    /// WHY: the seam's whole inbound contract is "the transport invokes the handler supplied at
    /// connect, once per chunk, in arrival order" — a test that only checked the bytes would pass
    /// against a transport that coalesced or reordered them.
    func testMockTransportDeliversInjectedChunksInOrder() async throws {
        let mock = MockTransport()
        let recorder = InboundRecorder()
        try await mock.connect(host: "localhost", port: 445, onReceive: recorder.handler)

        let first = Data("first".utf8)
        let second = Data("second".utf8)
        await mock.deliver(first)
        await mock.deliver(second)

        XCTAssertEqual(
            recorder.deliveredData, [first, second],
            "each injected chunk must reach the handler as its own delivery, in order"
        )
    }

    /// Scenario: Mock signals graceful EOF — exactly once, nothing afterwards.
    func testMockTransportSignalsGracefulEOFTerminalOnce() async throws {
        let mock = MockTransport()
        let recorder = InboundRecorder()
        try await mock.connect(host: "localhost", port: 445, onReceive: recorder.handler)

        await mock.signalGracefulEOF()
        // Terminal: neither a repeat EOF nor a later chunk may be delivered.
        await mock.signalGracefulEOF()
        await mock.deliver(Data("late".utf8))

        XCTAssertEqual(recorder.deliveryCount, 1, "EOF is terminal — exactly one delivery")
        XCTAssertEqual(
            recorder.deliveredData, [Data()],
            "graceful EOF is signalled by an empty Data delivery"
        )
    }

    /// Scenario: an injected error is delivered once as a `POSIXError` and is terminal.
    func testMockTransportSignalsErrorTerminalOnce() async throws {
        let mock = MockTransport()
        let recorder = InboundRecorder()
        try await mock.connect(host: "localhost", port: 445, onReceive: recorder.handler)

        await mock.signalError(POSIXError(.ECONNRESET))
        await mock.signalError(POSIXError(.EIO))
        await mock.deliver(Data("late".utf8))

        XCTAssertEqual(recorder.deliveryCount, 1, "abnormal loss is terminal — exactly one delivery")
        XCTAssertEqual(recorder.deliveredErrors.map(\.code), [.ECONNRESET])
    }

    /// Scenario: bytes queued before EOF are delivered before the EOF delivery.
    func testMockTransportDeliversChunksBeforeEOF() async throws {
        let mock = MockTransport()
        let recorder = InboundRecorder()
        try await mock.connect(host: "localhost", port: 445, onReceive: recorder.handler)

        let payload = Data("last bytes".utf8)
        await mock.deliver(payload)
        await mock.signalGracefulEOF()

        XCTAssertEqual(
            recorder.deliveredData, [payload, Data()],
            "chunks precede the terminal EOF delivery, in arrival order"
        )
    }

    // MARK: - MockTransport: outbound observation

    /// Scenario: Mock records sent bytes and never loops them back to the inbound handler.
    ///
    /// WHY: the loopback the mock used to have fed libsmb2 its own PDUs back; the sent log is
    /// how outbound delivery is observed now, so the directions must stay strictly separate.
    func testMockTransportRecordsSentBytesWithoutLoopback() async throws {
        let mock = MockTransport()
        let recorder = InboundRecorder()
        try await mock.connect(host: "localhost", port: 445, onReceive: recorder.handler)

        let first = Data("first".utf8)
        let second = Data("second".utf8)
        try await mock.send(first)
        try await mock.send(second)

        let sent = await mock.sentChunks()
        XCTAssertEqual(sent, [first, second], "sent bytes are recorded in send order")
        XCTAssertEqual(recorder.deliveryCount, 0, "sent bytes must never loop back inbound")
    }

    /// Scenario: `waitForSent(count:)` resolves once the sent log reaches the count.
    func testMockTransportWaitForSentResolvesWhenLogReachesCount() async throws {
        let mock = MockTransport()
        let recorder = InboundRecorder()
        try await mock.connect(host: "localhost", port: 445, onReceive: recorder.handler)

        let payload = Data("outbound".utf8)
        let waiter = Task { await mock.waitForSent(count: 1) }
        try await mock.send(payload)
        await waiter.value

        let sent = await mock.sentChunks()
        XCTAssertEqual(sent, [payload])
    }

    // MARK: - MockTransport: connect failure

    /// Scenario: Mock surfaces connection failure — and the failing connect never invokes the
    /// handler it was given (the seam's failed-connect contract).
    func testMockTransportSurfacesConnectFailureAndNeverDelivers() async {
        let mock = MockTransport(connectBehavior: .fail(POSIXError(.ECONNREFUSED)))
        let recorder = InboundRecorder()
        do {
            try await mock.connect(host: "localhost", port: 445, onReceive: recorder.handler)
            XCTFail("connect() must throw on .fail behaviour")
        } catch let posixError as POSIXError {
            XCTAssertEqual(posixError.code, .ECONNREFUSED)
        } catch {
            XCTFail("Expected POSIXError, got \(error)")
        }

        // Nothing may be delivered to a handler whose connect threw, even if the test then
        // tries to inject through the mock.
        await mock.deliver(Data("ignored".utf8))
        await mock.signalGracefulEOF()
        XCTAssertEqual(recorder.deliveryCount, 0, "a throwing connect never invokes its handler")
    }

    // MARK: - MockTransport: nothing after close

    /// Scenario: deliveries attempted after `close()` are not made.
    func testMockTransportDeliversNothingAfterClose() async throws {
        let mock = MockTransport()
        let recorder = InboundRecorder()
        try await mock.connect(host: "localhost", port: 445, onReceive: recorder.handler)

        await mock.deliver(Data("before".utf8))
        await mock.close()
        await mock.deliver(Data("after".utf8))
        await mock.signalGracefulEOF()
        await mock.signalError(POSIXError(.EIO))

        XCTAssertEqual(
            recorder.deliveredData, [Data("before".utf8)],
            "nothing is delivered once close() has begun"
        )
    }
}
