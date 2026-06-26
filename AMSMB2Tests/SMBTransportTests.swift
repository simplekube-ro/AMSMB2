//
//  SMBTransportTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Unit tests for the SMBTransport seam (T4 / issue #23).
//  Acceptance criteria:
//    - SMBTransport + SMBTransportKind compile and are public API
//    - MockTransport round-trips bytes, signals graceful EOF, surfaces
//      connect failure — with no server and no libsmb2 dependency
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

    // MARK: - MockTransport: round-trip

    /// Scenario: bytes written via send() are returned by receive().
    func testMockTransportRoundTripsBytes() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let payload = Data("hello SMB2 seam".utf8)
        try await mock.send(payload)
        let received = try await mock.receive()
        XCTAssertEqual(received, payload, "receive() must return the exact bytes passed to send()")
    }

    /// Scenario: multiple sequential send/receive pairs deliver in order.
    func testMockTransportDeliversInFIFOOrder() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        try await mock.send(first)
        try await mock.send(second)
        let receivedFirst = try await mock.receive()
        let receivedSecond = try await mock.receive()
        XCTAssertEqual(receivedFirst, first)
        XCTAssertEqual(receivedSecond, second)
    }

    // MARK: - MockTransport: graceful EOF

    /// Scenario: after signalGracefulEOF(), receive() returns empty Data.
    func testMockTransportSignalsGracefulEOF() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        await mock.signalGracefulEOF()
        let eofChunk = try await mock.receive()
        XCTAssertTrue(eofChunk.isEmpty, "EOF must be signalled by empty Data, got \(eofChunk.count) bytes")
    }

    /// Scenario: bytes queued before EOF are drained before EOF is delivered.
    func testMockTransportDrainsBufferBeforeEOF() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let payload = Data("last bytes".utf8)
        try await mock.send(payload)
        await mock.signalGracefulEOF()
        // First receive: queued bytes
        let bytes = try await mock.receive()
        XCTAssertEqual(bytes, payload)
        // Second receive: EOF
        let eof = try await mock.receive()
        XCTAssertTrue(eof.isEmpty)
    }

    // MARK: - MockTransport: connect failure

    /// Scenario: .fail connect behaviour causes connect() to throw POSIXError.
    func testMockTransportSurfacesConnectFailure() async {
        let mock = MockTransport(connectBehavior: .fail(POSIXError(.ECONNREFUSED)))
        do {
            try await mock.connect(host: "localhost", port: 445)
            XCTFail("connect() must throw on .fail behaviour")
        } catch let posixError as POSIXError {
            XCTAssertEqual(posixError.code, .ECONNREFUSED)
        } catch {
            XCTFail("Expected POSIXError, got \(error)")
        }
    }

    // MARK: - MockTransport: never-reply / cancellation

    /// Scenario: receive() suspended on an empty open mock can be cancelled
    /// via Task cancellation; the Task terminates without hanging.
    func testMockTransportNeverReplyCanBeCancelled() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)

        let task: Task<Data, any Error> = Task {
            try await mock.receive()
        }

        // Give the task a moment to suspend inside receive(), then cancel.
        try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected task to complete with an error after cancellation")
        } catch is CancellationError {
            // Expected: receive() was cancelled.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - MockTransport: concurrent send then receive

    /// Scenario: receive() suspends first, then send() resumes it —
    /// the concurrent flow that a bridge pump would exercise.
    func testMockTransportConcurrentSendResumesReceiver() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "localhost", port: 445)
        let payload = Data("concurrent".utf8)

        async let received = mock.receive()         // suspends immediately (buffer empty)
        try await mock.send(payload)                // resumes the suspended receive()
        let result = try await received
        XCTAssertEqual(result, payload)
    }
}
