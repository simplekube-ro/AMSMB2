//
//  SMB2IntegrationTests.swift
//  AMSMB2
//
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest

#if canImport(Darwin)
@preconcurrency import Darwin
#else
import FoundationNetworking
#endif
@testable import AMSMB2

private func fileName(postfix: String = "", name: String = #function) -> String {
    "\(name.trimmingCharacters(in: .init(charactersIn: "()")))\(postfix).dat"
}

private func folderName(postfix: String = "", name: String = #function) -> String {
    "\(name.trimmingCharacters(in: .init(charactersIn: "()")))\(postfix)"
}

class SMB2IntegrationTests: XCTestCase, @unchecked Sendable {
    lazy var server: URL = URL(string: ProcessInfo.processInfo.environment["SMB_SERVER"] ?? "smb://placeholder")!
    lazy var share: String = ProcessInfo.processInfo.environment["SMB_SHARE"] ?? ""
    lazy var credential: URLCredential? = {
        if let user = ProcessInfo.processInfo.environment["SMB_USER"],
           let pass = ProcessInfo.processInfo.environment["SMB_PASSWORD"]
        {
            return URLCredential(user: user, password: pass, persistence: .forSession)
        } else {
            return nil
        }
    }()
    lazy var encrypted: Bool = ProcessInfo.processInfo.environment["SMB_ENCRYPTED"] == "1"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SMB_SERVER"] != nil,
            "SMB server not configured"
        )
    }

    private func randomData(size: Int) -> Data {
        Data((0..<size).map { _ in UInt8.random(in: 0...UInt8.max) })
    }

    // MARK: - Append

    func testAppend() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        let original = randomData(size: 256)
        let extra = randomData(size: 128)

        addTeardownBlock {
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.write(data: original, toPath: file, progress: nil)

        try await smb.append(data: extra, toPath: file, offset: Int64(original.count), progress: nil)

        let result = try await smb.contents(atPath: file)
        XCTAssertEqual(result.count, original.count + extra.count)
        XCTAssertEqual(result.prefix(original.count), original)
        XCTAssertEqual(result.suffix(extra.count), Data(extra))
    }

    // MARK: - RemoveItem

    func testRemoveItemFile() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!

        addTeardownBlock {
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.write(data: Data([0x01, 0x02]), toPath: file, progress: nil)
        try await smb.removeItem(atPath: file)

        do {
            _ = try await smb.attributesOfItem(atPath: file)
            XCTFail("File should not exist after removeItem")
        } catch {}
    }

    func testRemoveItemDirectory() async throws {
        let dir = folderName()
        let smb = SMB2Manager(url: server, credential: credential)!

        addTeardownBlock {
            try? await smb.removeDirectory(atPath: dir, recursive: true)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.createDirectory(atPath: dir)
        try await smb.write(data: Data([0x01]), toPath: "\(dir)/file.dat", progress: nil)
        try await smb.removeItem(atPath: dir)

        do {
            _ = try await smb.attributesOfItem(atPath: dir)
            XCTFail("Directory should not exist after removeItem")
        } catch {}
    }

    // MARK: - CopyItem (replaces deprecated copyContentsOfItem)

    func testCopyItem() async throws {
        let src = fileName(postfix: "Src")
        let dst = fileName(postfix: "Dst")
        let smb = SMB2Manager(url: server, credential: credential)!
        let data = randomData(size: 512)

        addTeardownBlock {
            try? await smb.removeFile(atPath: src)
            try? await smb.removeFile(atPath: dst)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.write(data: data, toPath: src, progress: nil)
        try await smb.copyItem(atPath: src, toPath: dst, recursive: false, progress: nil)

        let result = try await smb.contents(atPath: dst)
        XCTAssertEqual(result, data)
    }

    // MARK: - Echo

    func testEcho() async throws {
        let smb = SMB2Manager(url: server, credential: credential)!
        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.echo()
    }

    func testEchoAfterDisconnect() async throws {
        let smb = SMB2Manager(url: server, credential: credential)!
        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.disconnectShare(gracefully: true)

        do {
            try await smb.echo()
            XCTFail("Echo should fail after disconnect")
        } catch {
            // Expected
        }
    }

    // MARK: - Progress Cancellation

    func testWriteProgressCancellation() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        let data = randomData(size: 4 * 1024 * 1024)

        addTeardownBlock {
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)

        do {
            try await smb.write(
                data: data, toPath: file,
                progress: { _ -> Bool in
                    return false
                }
            )
        } catch {
            // Cancellation is expected — either via error or partial write
        }
    }

    func testReadProgressCancellation() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        let data = randomData(size: 4 * 1024 * 1024)

        addTeardownBlock {
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.write(data: data, toPath: file, progress: nil)

        do {
            _ = try await smb.contents(
                atPath: file,
                progress: { _, _ -> Bool in
                    return false
                }
            )
        } catch {
            // Cancellation is expected
        }
    }

    // MARK: - Error Handling

    func testReadNonExistentPath() async throws {
        let smb = SMB2Manager(url: server, credential: credential)!
        try await smb.connectShare(name: share, encrypted: encrypted)

        do {
            _ = try await smb.contents(atPath: "nonexistent_file_\(UUID().uuidString).dat")
            XCTFail("Reading non-existent path should throw")
        } catch {
            let posixError = error as? POSIXError
            XCTAssertNotNil(posixError)
        }
    }

    func testConnectInvalidCredentials() async throws {
        let badCred = URLCredential(user: "baduser", password: "badpass", persistence: .forSession)
        let smb = SMB2Manager(url: server, credential: badCred)!

        do {
            try await smb.connectShare(name: share, encrypted: encrypted)
            XCTFail("Connect with invalid credentials should throw")
        } catch {
            // Expected authentication failure
        }
    }

    func testConnectNonExistentShare() async throws {
        let smb = SMB2Manager(url: server, credential: credential)!

        do {
            try await smb.connectShare(name: "nonexistent_share_\(UUID().uuidString)", encrypted: encrypted)
            XCTFail("Connect to non-existent share should throw")
        } catch {
            // Expected
        }
    }

    // MARK: - smbClient Accessor

    func testSmbClientAccessorAfterConnect() async throws {
        let smb = SMB2Manager(url: server, credential: credential)!
        try await smb.connectShare(name: share, encrypted: encrypted)

        let client = try smb.smbClient
        XCTAssertTrue(client.isConnected)
    }

    func testSmbClientAccessorBeforeConnect() throws {
        let smb = SMB2Manager(url: server, credential: credential)!

        XCTAssertThrowsError(try smb.smbClient) { error in
            let posixError = error as? POSIXError
            XCTAssertNotNil(posixError)
            XCTAssertEqual(posixError?.code, .ENOTCONN)
        }
    }
}
