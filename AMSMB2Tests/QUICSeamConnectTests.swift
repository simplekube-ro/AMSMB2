//
//  QUICSeamConnectTests.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

//
//  QUICSeamConnectTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Apple-only tests for the QUIC connect policy wired through
//  `SMB2Client.connect(server:share:user:transportKind:quicConfiguration:)` (design D4/D9/D10):
//  per-kind default port and selector exactness, numeric-host rejection independent of the TLS
//  trust policy, and connect-timeout validation — all of which must fire *before* the `.quic`
//  branch constructs `QUICTransportApple` (or throws `ENOTSUP` below the availability floor).
//  Guarded like the rest of the seam (`#if canImport(Network)`).
//

#if canImport(Network)

import SMB2
import XCTest
@testable import AMSMB2

final class QUICSeamConnectTests: XCTestCase, @unchecked Sendable {
    // MARK: - Per-kind selector exactness (design D9)

    /// WHEN a seam connect installs the external transport
    /// THEN `.tcp`/`.automatic` map to `SMB2_TRANSPORT_AUTO` and `.quic` to `SMB2_TRANSPORT_QUIC`
    /// — never `SMB2_TRANSPORT_TCP` (which would ignore `ext`), and `.automatic` never yields QUIC.
    func testSeamSelectorPerKindIsExact() {
        XCTAssertEqual(SMB2Client.seamSelector(for: .tcp), SMB2_TRANSPORT_AUTO)
        XCTAssertEqual(SMB2Client.seamSelector(for: .automatic), SMB2_TRANSPORT_AUTO)
        XCTAssertEqual(SMB2Client.seamSelector(for: .quic), SMB2_TRANSPORT_QUIC)

        // `.automatic` must never select QUIC (design D9 / quic-connection-policy).
        XCTAssertNotEqual(SMB2Client.seamSelector(for: .automatic), SMB2_TRANSPORT_QUIC)
        // Guard the naming trap: the external-transport selector is never TCP (== 0).
        XCTAssertNotEqual(SMB2Client.seamSelector(for: .tcp), SMB2_TRANSPORT_TCP)
        XCTAssertNotEqual(SMB2Client.seamSelector(for: .quic), SMB2_TRANSPORT_TCP)
    }

    // MARK: - Per-kind default port (design D4)

    /// WHEN the server string carries no explicit port
    /// THEN `.tcp`/`.automatic` default to 445 and `.quic` to 443.
    func testSeamDefaultPortPerKind() {
        XCTAssertEqual(SMB2Client.seamDefaultPort(for: .tcp), 445)
        XCTAssertEqual(SMB2Client.seamDefaultPort(for: .automatic), 445)
        XCTAssertEqual(SMB2Client.seamDefaultPort(for: .quic), 443)
    }

    // MARK: - Numeric-host rejection (design D4)

    /// WHEN `.quic` connects to a numeric host
    /// THEN it throws `POSIXError(.EINVAL)` specifically — not `ENOTSUP` and not a connect-class
    /// error — proving the rejection fired in the validation step that precedes transport
    /// construction and any network activity.
    func testQuicNumericHostThrowsEINVALBeforeTransport() async throws {
        let client = try SMB2Client(timeout: 5)
        do {
            try await client.connect(
                server: "192.168.1.10", share: "share", user: "user",
                transportKind: .quic, quicConfiguration: nil
            )
            XCTFail("QUIC to a numeric host must throw before any transport is constructed")
        } catch let posix as POSIXError {
            XCTAssertEqual(
                posix.code, .EINVAL,
                "numeric host must be EINVAL, not ENOTSUP or a connect-class error"
            )
        }
        XCTAssertFalse(client.isConnected, "no seam session on a rejected numeric host")
    }

    /// WHEN `.quic` connects to a numeric host with `.insecureNoVerification`
    /// THEN it still throws `POSIXError(.EINVAL)` — numeric rejection precedes and is independent
    /// of the TLS trust policy; the insecure escape hatch never bypasses it (design D4).
    func testQuicNumericHostRejectedEvenWithInsecureTrustPolicy() async throws {
        let client = try SMB2Client(timeout: 5)
        let config = SMBQUICConfiguration(trustPolicy: .insecureNoVerification)
        do {
            try await client.connect(
                server: "192.168.1.10", share: "share", user: "user",
                transportKind: .quic, quicConfiguration: config
            )
            XCTFail("insecure trust policy must not bypass numeric-host rejection")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EINVAL, "must still be EINVAL under .insecureNoVerification")
        }
    }

    // MARK: - Explicit-port range validation (design D4, P2 overflow regression)

    /// WHEN `.quic` connects with an explicit port outside 1...65535 — including an oversized
    /// digit string hundreds of characters long (which previously trapped in the leading-digit
    /// parser before any range check could run) and the bracketed-host form
    /// THEN connect throws `POSIXError(.EINVAL)` from the endpoint validation that precedes
    /// transport construction — it never traps and never reaches a transport or the
    /// `NWConnection` driver factory.
    func testQuicOutOfRangeOrOversizedPortThrowsEINVALBeforeTransport() async throws {
        let nines = String(repeating: "9", count: 300)
        for server in [
            "fs.example.com:\(nines)",
            "[fs.example.com]:\(nines)",
            "fs.example.com:65536",
            "fs.example.com:0",
        ] {
            let client = try SMB2Client(timeout: 5)
            do {
                try await client.connect(
                    server: server, share: "share", user: "user",
                    transportKind: .quic, quicConfiguration: nil
                )
                XCTFail("out-of-range port in \(server.prefix(24))… must throw before any transport")
            } catch let posix as POSIXError {
                XCTAssertEqual(
                    posix.code, .EINVAL,
                    "out-of-range port must be EINVAL, not a trap or a connect-class error"
                )
            }
            XCTAssertFalse(client.isConnected, "no seam session on a rejected port")
        }
    }

    // MARK: - Connect-timeout validation wired into the hoisted step (design D10)

    /// WHEN `.quic` connects with an invalid `connectTimeout` to a non-numeric host
    /// THEN it throws `POSIXError(.EINVAL)` from the connect-timeout normalization — before the
    /// transport is constructed and before any network activity.
    func testQuicInvalidConnectTimeoutThrowsEINVAL() async throws {
        let client = try SMB2Client(timeout: 5)
        for badTimeout in [0.0, -1.0, Double.nan, Double.infinity] {
            let config = SMBQUICConfiguration(connectTimeout: badTimeout)
            do {
                try await client.connect(
                    server: "fs.example.com", share: "share", user: "user",
                    transportKind: .quic, quicConfiguration: config
                )
                XCTFail("invalid connectTimeout \(badTimeout) must be rejected")
            } catch let posix as POSIXError {
                XCTAssertEqual(
                    posix.code, .EINVAL,
                    "invalid connectTimeout \(badTimeout) must be EINVAL, not ENOTSUP"
                )
            }
        }
    }

    /// WHEN `SMB2Manager.timeout` (the client's per-operation timeout) is zero or negative — its
    /// documented "disable operation timeouts" contract — and `.quic` is attempted with an
    /// **invalid** connect timeout
    /// THEN the QUIC connect-deadline validation is unaffected by the operation timeout: it still
    /// rejects the invalid `connectTimeout` with `EINVAL`, proving the QUIC connect deadline is
    /// sourced from `SMBQUICConfiguration.connectTimeout`, independent of `SMB2Client.timeout`
    /// (design D10). (The arming of a *valid* deadline is covered deterministically at the
    /// transport level in `QUICTransportAppleTests`.)
    func testQuicConnectTimeoutIndependentOfOperationTimeout() async throws {
        for operationTimeout in [0.0, -5.0] {
            let client = try SMB2Client(timeout: operationTimeout)
            do {
                try await client.connect(
                    server: "fs.example.com", share: "share", user: "user",
                    transportKind: .quic,
                    quicConfiguration: SMBQUICConfiguration(connectTimeout: 0)
                )
                XCTFail("expected EINVAL from the QUIC connect-timeout validation")
            } catch let posix as POSIXError {
                XCTAssertEqual(
                    posix.code, .EINVAL,
                    "a zero/negative operation timeout must not change QUIC connect-timeout validation"
                )
            }
        }
    }

    // MARK: - Factored endpoint validation (design D4)

    /// WHEN `validatedQUICEndpoint(_:)` parses a server string carrying no explicit port
    /// THEN it yields the host unchanged and the `.quic` default port 443 — the probe and the
    /// `.quic` connect branch therefore target the same endpoint for the same input.
    func testValidatedQUICEndpointDefaultsToPort443() throws {
        let endpoint = try SMB2Client.validatedQUICEndpoint("fs.example.com")
        XCTAssertEqual(endpoint.host, "fs.example.com")
        XCTAssertEqual(endpoint.port, 443)
    }

    /// WHEN the server string carries an explicit in-range port
    /// THEN it is honored verbatim (no silent rewrite to 443).
    func testValidatedQUICEndpointHonorsExplicitPort() throws {
        let endpoint = try SMB2Client.validatedQUICEndpoint("fs.example.com:4433")
        XCTAssertEqual(endpoint.host, "fs.example.com")
        XCTAssertEqual(endpoint.port, 4433)
    }

    /// WHEN the server string is a numeric address — plain IPv4 or the bracketed IPv6 literal
    /// form, which parses to a bare numeric host
    /// THEN `validatedQUICEndpoint` throws `POSIXError(.EINVAL)`, exactly as the `.quic` connect
    /// branch does: the two callers share one classifier and cannot diverge.
    func testValidatedQUICEndpointRejectsNumericHost() throws {
        for server in ["192.168.1.10", "[::1]", "127.1", "2130706433"] {
            XCTAssertThrowsError(try SMB2Client.validatedQUICEndpoint(server), server) { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EINVAL, "\(server) must be EINVAL")
            }
        }
    }

    /// WHEN the server string carries an explicit port outside 1...65535 — including an oversized
    /// digit string that must never trap the leading-digit parser
    /// THEN `validatedQUICEndpoint` throws `POSIXError(.EINVAL)`.
    func testValidatedQUICEndpointRejectsOutOfRangePort() throws {
        let nines = String(repeating: "9", count: 300)
        for server in ["fs.example.com:0", "fs.example.com:65536", "fs.example.com:\(nines)"] {
            XCTAssertThrowsError(try SMB2Client.validatedQUICEndpoint(server), server.prefix(24).description) { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EINVAL, "out-of-range port must be EINVAL")
            }
        }
    }

    /// WHEN `validateQUICEndpoint(host:port:)` is handed an already-parsed pair
    /// THEN a hostname with an in-range port passes, and a numeric host or an out-of-range port
    /// throws `EINVAL` — this is the exact check the `.quic` connect branch performs on the
    /// endpoint it parsed once, so factoring it out cannot change connect behavior.
    func testValidateQUICEndpointOnPreParsedPair() throws {
        XCTAssertNoThrow(try SMB2Client.validateQUICEndpoint(host: "fs.example.com", port: 443))
        XCTAssertNoThrow(try SMB2Client.validateQUICEndpoint(host: "fs.example.com", port: 65535))
        XCTAssertThrowsError(try SMB2Client.validateQUICEndpoint(host: "192.168.1.10", port: 443)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EINVAL)
        }
        XCTAssertThrowsError(try SMB2Client.validateQUICEndpoint(host: "", port: 443)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EINVAL, "an empty host is not a usable hostname")
        }
        XCTAssertThrowsError(try SMB2Client.validateQUICEndpoint(host: "fs.example.com", port: 0)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EINVAL)
        }
        XCTAssertThrowsError(try SMB2Client.validateQUICEndpoint(host: "fs.example.com", port: 65536)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EINVAL)
        }
    }
}

#endif // canImport(Network)
