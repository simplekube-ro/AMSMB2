//
//  SMB2SeamConnectOrderingTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Unit tests for fix-seam-connect-ordering: the eager-connect ordering, the seam
//  endpoint parser (mirrors libsmb2 ext_connect), and connect-failure teardown.
//
//  Apple-only (#if canImport(Network)) because the seam — `TransportBridge`,
//  `TCPTransportApple`, and `connectWithBridge` — is guarded the same way (design D7).
//

#if canImport(Network)

import XCTest

@testable import AMSMB2

final class SMB2SeamConnectOrderingTests: XCTestCase, @unchecked Sendable {

    // MARK: - Host/port parser table (mirrors transport-external.c ext_connect)

    /// WHEN a libsmb2 `server` string is parsed
    /// THEN host/port match libsmb2's `ext_connect` parser byte-for-byte.
    func testParseSeamEndpointTable() throws {
        func assertParse(
            _ server: String, defaultPort: Int = 445, host: String, port: Int,
            line: UInt = #line
        ) throws {
            let parsed = try SMB2Client.parseSeamEndpoint(server, defaultPort: defaultPort)
            XCTAssertEqual(parsed.host, host, "host for \(server)", line: line)
            XCTAssertEqual(parsed.port, port, "port for \(server)", line: line)
        }

        try assertParse("host", host: "host", port: 445)
        try assertParse("host:1445", host: "host", port: 1445)
        try assertParse("[::1]", host: "::1", port: 445)
        try assertParse("[::1]:1445", host: "::1", port: 1445)
        try assertParse("127.0.0.1:445", host: "127.0.0.1", port: 445)
        try assertParse("127.0.0.1", host: "127.0.0.1", port: 445)

        // Per-kind default port (design D4): 443 is used for `.quic` when no port is present,
        // while an explicit port still wins regardless of the default.
        try assertParse("host", defaultPort: 443, host: "host", port: 443)
        try assertParse("[::1]", defaultPort: 443, host: "::1", port: 443)
        try assertParse("host:1445", defaultPort: 443, host: "host", port: 1445)
    }

    /// WHEN an IPv6 literal is missing its closing `]`
    /// THEN parsing throws `POSIXError(.EINVAL)` (mirrors the C error path).
    func testParseSeamEndpointMissingBracketThrows() {
        XCTAssertThrowsError(try SMB2Client.parseSeamEndpoint("[bad", defaultPort: 445)) { error in
            guard let posix = error as? POSIXError else {
                return XCTFail("expected POSIXError, got \(error)")
            }
            XCTAssertEqual(posix.code, .EINVAL)
        }
    }

    // MARK: - Connect-failure teardown (binding mandate D-FIX-2 #2)

    /// WHEN the transport's `connect` throws
    /// THEN `connectWithBridge` throws the mapped `POSIXError` (NOT `EPERM`/`.init(1)`)
    /// AND no libsmb2 operation is left registered (the failure occurs before any handshake).
    func testConnectFailurePropagatesAndDoesNotRegisterOperation() async throws {
        let client = try SMB2Client(timeout: 30)
        let mock = MockTransport(connectBehavior: .fail(POSIXError(.ECONNREFUSED)))
        let bridge = TransportBridge(transport: mock)

        do {
            try await client.connectWithBridge(
                server: "127.0.0.1", share: "share", user: "user",
                host: "127.0.0.1", port: 445,
                bridge: bridge, selector: SMB2Client.seamSelector(for: .automatic)
            )
            XCTFail("connectWithBridge must throw when the transport connect fails")
        } catch let posix as POSIXError {
            // Must be the propagated transport error (ECONNREFUSED), NOT the old downstream
            // symptom EPERM (`POSIXError(.init(1))` from mapping libsmb2's status -1).
            XCTAssertEqual(
                posix.code, .ECONNREFUSED,
                "the transport connect error must propagate, not be mapped to EPERM"
            )
        }

        // The failure happened before any operation was registered: the client never became
        // seam-connected.
        XCTAssertFalse(client.isConnected, "no seam session should be established on connect failure")
    }
}

#endif // canImport(Network)
