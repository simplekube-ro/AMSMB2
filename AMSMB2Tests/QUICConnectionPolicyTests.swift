//
//  QUICConnectionPolicyTests.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest
@testable import AMSMB2

final class QUICConnectionPolicyTests: XCTestCase, @unchecked Sendable {
    // MARK: - isNumericHost rejection table (design D4 acceptance criteria)

    /// WHEN a host string is a numeric IPv4/IPv6 address in any form (or empty)
    /// THEN `isNumericHost` classifies it as numeric (rejected by the QUIC policy).
    ///
    /// This is the required acceptance table — a platform miss is fixed by supplementing the
    /// classifier, never by shrinking the table. The bracketed IPv6 form `[fe80::1]` is covered
    /// because `parseSeamEndpoint` strips the brackets before classification, so the classifier
    /// sees `fe80::1` (asserted here directly).
    func testNumericHostsAreRejected() {
        let numeric = [
            "192.168.1.10", // dotted quad
            "127.1", // legacy short form
            "2130706433", // decimal integer
            "0x7f000001", // hexadecimal
            "0177.0.0.1", // octal
            "fe80::1", // IPv6 (also the bracket-stripped [fe80::1])
            "fe80::1%en0", // scoped IPv6
            "::ffff:192.168.1.10", // IPv4-mapped IPv6
            "", // empty host — not a usable hostname
        ]
        for host in numeric {
            XCTAssertTrue(
                SMB2Client.isNumericHost(host),
                "\(host.isEmpty ? "<empty>" : host) must be classified as numeric (rejected)"
            )
        }
    }

    /// WHEN a host string is a non-numeric name
    /// THEN `isNumericHost` classifies it as a hostname (accepted by the QUIC policy).
    ///
    /// The rule is "non-numeric hostnames only": `localhost`, single-label names, and other
    /// non-numeric names that may later fail DNS are accepted here and fail (if at all) later.
    func testNonNumericHostsAreAccepted() {
        let names = [
            "fs.example.com",
            "localhost",
            "server", // single label
            "1password.example.com", // contains digits
            "fs.example.com.", // trailing-dot FQDN
        ]
        for host in names {
            XCTAssertFalse(
                SMB2Client.isNumericHost(host),
                "\(host) must be classified as a hostname (accepted)"
            )
        }
    }

    // MARK: - normalizedQUICConnectTimeout boundaries (design D10)

    /// WHEN the connect timeout is non-finite or non-positive
    /// THEN normalization throws `POSIXError(.EINVAL)` — the deadline can never be disabled.
    func testConnectTimeoutInvalidValuesThrowEINVAL() {
        let invalid: [TimeInterval] = [
            .nan, .infinity, -.infinity, 0, -1, -0.5,
        ]
        for value in invalid {
            XCTAssertThrowsError(
                try SMB2Client.normalizedQUICConnectTimeout(value),
                "\(value) must be rejected"
            ) { error in
                guard let posix = error as? POSIXError else {
                    return XCTFail("expected POSIXError, got \(error)")
                }
                XCTAssertEqual(posix.code, .EINVAL, "\(value) must throw EINVAL")
            }
        }
    }

    /// WHEN the connect timeout exceeds 3600 s
    /// THEN it is clamped to 3600; `3600` itself passes unclamped; sub-second values pass through.
    func testConnectTimeoutClampingAndPassthrough() throws {
        XCTAssertEqual(try SMB2Client.normalizedQUICConnectTimeout(3601), 3600, "over-limit clamps")
        XCTAssertEqual(
            try SMB2Client.normalizedQUICConnectTimeout(100_000), 3600, "far over-limit clamps"
        )
        XCTAssertEqual(try SMB2Client.normalizedQUICConnectTimeout(3600), 3600, "3600 is unclamped")
        XCTAssertEqual(try SMB2Client.normalizedQUICConnectTimeout(30), 30, "default passes through")
        XCTAssertEqual(
            try SMB2Client.normalizedQUICConnectTimeout(0.25), 0.25, "sub-second passes through"
        )
    }
}
