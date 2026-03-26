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

    func testEventLoopQueueQoS() throws {
        let client = try SMB2Client(timeout: 30)
        XCTAssertEqual(
            client.eventLoopQueue.qos, .userInitiated,
            "eventLoopQueue must run at .userInitiated to avoid priority inversion"
        )
        XCTAssertTrue(
            client.eventLoopQueue.label.hasPrefix("smb2_eventloop_"),
            "eventLoopQueue label must follow the smb2_eventloop_<address> pattern"
        )
    }

    func testInitWithInvalidURL() {
        let httpURL = URL(string: "http://192.168.1.1/share")!
        let credential = URLCredential(user: "user", password: "password", persistence: .forSession)
        XCTAssertNil(SMB2Manager(url: httpURL, credential: credential))

        let ftpURL = URL(string: "ftp://192.168.1.1/share")!
        XCTAssertNil(SMB2Manager(url: ftpURL, credential: credential))
    }

    // MARK: - Credential Exposure Tests

    func testCodableOmitsPassword() throws {
        let url = URL(string: "smb://192.168.1.1/share")!
        let credential = URLCredential(user: "user", password: "s3cret", persistence: .forSession)
        let smb = SMB2Manager(url: url, credential: credential)!

        let json = try JSONEncoder().encode(smb)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        XCTAssertNil(dict["password"], "Password must not appear in Codable JSON output")
    }

    func testCodableDecodesLegacyArchive() throws {
        // Simulate a legacy archive that includes a password field
        let legacyJSON = """
        {"url":"smb:\\/\\/192.168.1.1\\/share","user":"user","password":"s3cret","timeout":60}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SMB2Manager.self, from: legacyJSON)
        XCTAssertEqual(decoded.url, URL(string: "smb://192.168.1.1/share")!)

        // Re-encode and verify password is not persisted
        let reEncoded = try JSONEncoder().encode(decoded)
        let dict = try JSONSerialization.jsonObject(with: reEncoded) as! [String: Any]
        XCTAssertNil(dict["password"], "Password must not survive a re-encode cycle")
    }

    @available(iOS 11.0, macOS 10.13, tvOS 11.0, *)
    func testNSCodingOmitsPassword() throws {
        let url = URL(string: "smb://192.168.1.1/share")!
        let credential = URLCredential(user: "user", password: "s3cret", persistence: .forSession)
        let smb = SMB2Manager(url: url, credential: credential)!

        // Archive and unarchive
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(smb, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        let decoded = unarchiver.decodeObject(
            of: SMB2Manager.self, forKey: NSKeyedArchiveRootObjectKey
        )!

        // Verify password is empty by re-encoding to JSON and checking
        let json = try JSONEncoder().encode(decoded)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertNil(dict["password"], "Password must not survive NSCoding round-trip")
    }

    func testDebugDescriptionRedactsCredentials() {
        let url = URL(string: "smb://192.168.1.1/share")!
        let credential = URLCredential(user: "testuser123", password: "s3cret", persistence: .forSession)
        let smb = SMB2Manager(url: url, credential: credential)!

        let description = smb.debugDescription
        XCTAssertFalse(
            description.contains("testuser123"),
            "debugDescription must not contain the username"
        )
        XCTAssertTrue(
            description.contains("<redacted>"),
            "debugDescription must contain <redacted> placeholder"
        )
        XCTAssertFalse(
            description.contains("s3cret"),
            "debugDescription must not contain the password"
        )
    }

    func testCustomMirrorDomainWorkstation() {
        let url = URL(string: "smb://192.168.1.1/share")!

        // Manager with domain (via parameter) and workstation (via "WS1\user" format)
        let credential = URLCredential(user: "WS1\\user", password: "pass", persistence: .forSession)
        let smbWithBoth = SMB2Manager(url: url, domain: "CORP", credential: credential)!

        let labels = smbWithBoth.customMirror.children.compactMap(\.label)
        XCTAssertTrue(labels.contains("domain"), "Mirror must include domain when non-empty")
        XCTAssertTrue(labels.contains("workstation"), "Mirror must include workstation when non-empty")

        // Workstation must appear exactly once (bug fix: duplicate line removal)
        let wsCount = labels.filter { $0 == "workstation" }.count
        XCTAssertEqual(wsCount, 1, "Workstation must appear exactly once in mirror")

        // Manager with empty domain and workstation
        let simpleCred = URLCredential(user: "user", password: "pass", persistence: .forSession)
        let smbEmpty = SMB2Manager(url: url, credential: simpleCred)!

        let emptyLabels = smbEmpty.customMirror.children.compactMap(\.label)
        XCTAssertFalse(
            emptyLabels.contains("domain"),
            "Mirror must NOT include domain when empty"
        )
        XCTAssertFalse(
            emptyLabels.contains("workstation"),
            "Mirror must NOT include workstation when empty"
        )
    }

    func testCopyPreservesPassword() throws {
        let url = URL(string: "smb://192.168.1.1/share")!
        let credential = URLCredential(user: "user", password: "s3cret", persistence: .forSession)
        let smb = SMB2Manager(url: url, credential: credential)!

        let smbCopy = smb.copy() as! SMB2Manager

        // Copy should preserve URL
        XCTAssertEqual(smb.url, smbCopy.url)

        // Verify copy is independent by encoding — password should still be absent from encoding
        let json = try JSONEncoder().encode(smbCopy)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertNil(dict["password"], "Copied manager must also omit password from encoding")
        XCTAssertEqual(dict["user"] as? String, "user")
    }
}
