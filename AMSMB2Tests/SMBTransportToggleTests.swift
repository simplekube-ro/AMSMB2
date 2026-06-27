//
//  SMBTransportToggleTests.swift
//  AMSMB2
//
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest
@testable import AMSMB2

/// Unit coverage for the `SMB_TRANSPORT` env toggle mapping (T8.1). Runs without a server.
final class SMBTransportToggleTests: XCTestCase {
    func testUnsetMapsToLegacy() {
        XCTAssertNil(SMBIntegrationTestCase.transportKind(forEnvValue: nil))
    }

    func testLegacyKeywordMapsToLegacy() {
        XCTAssertNil(SMBIntegrationTestCase.transportKind(forEnvValue: "legacy"))
        XCTAssertNil(SMBIntegrationTestCase.transportKind(forEnvValue: "LEGACY"))
    }

    func testUnknownValueMapsToLegacy() {
        XCTAssertNil(SMBIntegrationTestCase.transportKind(forEnvValue: ""))
        XCTAssertNil(SMBIntegrationTestCase.transportKind(forEnvValue: "quic"))
        XCTAssertNil(SMBIntegrationTestCase.transportKind(forEnvValue: "bogus"))
    }

    func testSeamKeywordsMapToAutomatic() {
        for value in ["seam", "tcp", "auto", "automatic"] {
            XCTAssertEqual(
                SMBIntegrationTestCase.transportKind(forEnvValue: value), .automatic,
                "\(value) should select the seam"
            )
        }
    }

    func testSeamKeywordsAreCaseInsensitive() {
        XCTAssertEqual(SMBIntegrationTestCase.transportKind(forEnvValue: "Seam"), .automatic)
        XCTAssertEqual(SMBIntegrationTestCase.transportKind(forEnvValue: "TCP"), .automatic)
        XCTAssertEqual(SMBIntegrationTestCase.transportKind(forEnvValue: "Automatic"), .automatic)
    }
}
