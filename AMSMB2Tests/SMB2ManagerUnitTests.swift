//
//  SMB2ManagerUnitTests.swift
//  AMSMB2
//
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest

@testable import AMSMB2

class SMB2ManagerUnitTests: XCTestCase, @unchecked Sendable {
    @available(iOS 11.0, macOS 10.13, tvOS 11.0, *)
    func testNSCodable() {
        let url = URL(string: "smb://192.168.1.1/share")!
        let credential = URLCredential(user: "user", password: "password", persistence: .forSession)
        let smb = SMB2Manager(url: url, credential: credential)
        XCTAssertNotNil(smb)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(smb, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let data = archiver.encodedData
        XCTAssertNil(archiver.error)
        XCTAssertFalse(data.isEmpty)
        let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.requiresSecureCoding = true
        let decodedSMB = unarchiver.decodeObject(
            of: SMB2Manager.self, forKey: NSKeyedArchiveRootObjectKey
        )
        XCTAssertNotNil(decodedSMB)
        XCTAssertEqual(smb?.url, decodedSMB?.url)
        XCTAssertEqual(smb?.timeout, decodedSMB?.timeout)
        XCTAssertNil(unarchiver.error)
    }

    func testCoding() {
        let url = URL(string: "smb://192.168.1.1/share")!
        let credential = URLCredential(user: "user", password: "password", persistence: .forSession)
        let smb = SMB2Manager(url: url, domain: "", credential: credential)
        XCTAssertNotNil(smb)
        do {
            let encoder = JSONEncoder()
            let json = try encoder.encode(smb!)
            XCTAssertFalse(json.isEmpty)
            let decoder = JSONDecoder()
            let decodedSMB = try decoder.decode(SMB2Manager.self, from: json)
            XCTAssertEqual(smb!.url, decodedSMB.url)
            XCTAssertEqual(smb!.timeout, decodedSMB.timeout)

            let errorJson = String(data: json, encoding: .utf8)!.replacingOccurrences(
                of: "smb:", with: "smb2:"
            ).data(using: .utf8)!
            XCTAssertThrowsError(try decoder.decode(SMB2Manager.self, from: errorJson))
        } catch {
            XCTAssert(false, error.localizedDescription)
        }
    }

    func testNSCopy() {
        let url = URL(string: "smb://192.168.1.1/share")!
        let credential = URLCredential(user: "user", password: "password", persistence: .forSession)
        let smb = SMB2Manager(url: url, domain: "", credential: credential)!
        let smbCopy = smb.copy() as! SMB2Manager
        XCTAssertEqual(smb.url, smbCopy.url)
    }

    func testInitWithInvalidURL() {
        let httpURL = URL(string: "http://192.168.1.1/share")!
        let credential = URLCredential(user: "user", password: "password", persistence: .forSession)
        XCTAssertNil(SMB2Manager(url: httpURL, credential: credential))

        let ftpURL = URL(string: "ftp://192.168.1.1/share")!
        XCTAssertNil(SMB2Manager(url: ftpURL, credential: credential))
    }
}
