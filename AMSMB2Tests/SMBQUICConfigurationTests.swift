//
//  SMBQUICConfigurationTests.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest
@testable import AMSMB2

final class SMBQUICConfigurationTests: XCTestCase, @unchecked Sendable {
    // MARK: - Defaults (design D5/D10)

    /// WHEN a configuration is created with no arguments
    /// THEN `trustPolicy` defaults to `.system` and `connectTimeout` to 30 seconds.
    func testDefaults() {
        let config = SMBQUICConfiguration()
        XCTAssertEqual(config.trustPolicy, .system, "trustPolicy must default to .system")
        XCTAssertEqual(config.connectTimeout, 30, "connectTimeout must default to 30 seconds")
    }

    /// WHEN the memberwise initializer is used with explicit values
    /// THEN the stored values reflect them.
    func testMemberwiseInit() {
        let config = SMBQUICConfiguration(
            trustPolicy: .insecureNoVerification, connectTimeout: 5
        )
        XCTAssertEqual(config.trustPolicy, .insecureNoVerification)
        XCTAssertEqual(config.connectTimeout, 5)
    }

    // MARK: - Equatable

    /// WHEN two configurations hold equal values
    /// THEN they compare equal; distinct values compare unequal.
    func testEquatable() {
        XCTAssertEqual(SMBQUICConfiguration(), SMBQUICConfiguration())
        XCTAssertEqual(
            SMBQUICConfiguration(trustPolicy: .customRoots([Data([0x01])]), connectTimeout: 12),
            SMBQUICConfiguration(trustPolicy: .customRoots([Data([0x01])]), connectTimeout: 12)
        )
        XCTAssertNotEqual(
            SMBQUICConfiguration(trustPolicy: .system),
            SMBQUICConfiguration(trustPolicy: .insecureNoVerification)
        )
        XCTAssertNotEqual(
            SMBQUICConfiguration(connectTimeout: 30),
            SMBQUICConfiguration(connectTimeout: 60)
        )
        XCTAssertNotEqual(
            SMBQUICConfiguration(trustPolicy: .customRoots([Data([0x01])])),
            SMBQUICConfiguration(trustPolicy: .customRoots([Data([0x02])]))
        )
    }

    // MARK: - Trust policy shape (mutual exclusion by construction, design D5)

    /// WHEN the trust policy is expressed
    /// THEN "custom roots + insecure" is unrepresentable: `TrustPolicy` is a single enum,
    /// so exactly one case is selected at any time — there is no independent
    /// `trustedRoots`/`allowsInsecureTrust` pair that could conflict. This is an API-shape
    /// assertion: each case is distinct and carries only its own payload.
    func testTrustPolicyMutualExclusionByConstruction() {
        let system: SMBQUICConfiguration.TrustPolicy = .system
        let insecure: SMBQUICConfiguration.TrustPolicy = .insecureNoVerification
        let roots: SMBQUICConfiguration.TrustPolicy = .customRoots([Data([0xab])])

        // Distinct cases never compare equal — you cannot be "custom roots AND insecure".
        XCTAssertNotEqual(system, insecure)
        XCTAssertNotEqual(system, roots)
        XCTAssertNotEqual(insecure, roots)

        // A custom-roots policy carries exactly its anchors and nothing else.
        if case .customRoots(let anchors) = roots {
            XCTAssertEqual(anchors, [Data([0xab])])
        } else {
            XCTFail("expected .customRoots to preserve its anchor payload")
        }
    }

    // MARK: - Sendable / platform-neutral

    /// Compile-time assertion: `SMBQUICConfiguration` is `Sendable`. If the type (or any
    /// stored property) lost `Sendable`, this generic constraint would fail to compile.
    func testIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T {
            value
        }
        let config = requireSendable(SMBQUICConfiguration(trustPolicy: .customRoots([Data()])))
        XCTAssertEqual(config.trustPolicy, .customRoots([Data()]))
    }

    /// The trust material is DER `[Data]` and the timeout is `TimeInterval` — no
    /// Security.framework (`SecCertificate`) or Network.framework type participates, so the
    /// type is platform-neutral. This test simply constructs the type from primitive values,
    /// documenting the neutral surface; its real teeth are that this file has no
    /// `#if canImport(Network)` guard, so it must compile on Linux.
    func testPlatformNeutralSurface() {
        let der: [Data] = [Data([0x30, 0x82])]
        let config = SMBQUICConfiguration(
            trustPolicy: .customRoots(der), connectTimeout: 15
        )
        XCTAssertEqual(config.trustPolicy, .customRoots(der))
        XCTAssertEqual(config.connectTimeout, 15)
    }
}
