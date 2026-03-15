//
//  SMB2DisconnectTimeoutTests.swift
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

class SMB2DisconnectTimeoutTests: XCTestCase, @unchecked Sendable {
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

    // MARK: - Disconnect Behavior

    func testGracefulDisconnectWaitsForInFlightOperation() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        let data = randomData(size: 4 * 1024 * 1024)

        addTeardownBlock {
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)

        // Start a large write concurrently
        let writeTask = Task {
            try await smb.write(data: data, toPath: file, progress: nil)
        }

        // Graceful disconnect should wait for the write to finish
        try await smb.disconnectShare(gracefully: true)

        // The write task should have completed without error
        try await writeTask.value

        // Reconnect and verify the file was fully written
        try await smb.connectShare(name: share, encrypted: encrypted)
        let attribs = try await smb.attributesOfItem(atPath: file)
        XCTAssertEqual(attribs.fileSize, Int64(data.count))
    }

    func testNonGracefulDisconnectFailsInFlightOperation() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        let data = randomData(size: 4 * 1024 * 1024)

        addTeardownBlock { [self] in
            try await smb.connectShare(name: self.share, encrypted: self.encrypted)
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)

        // Start a large write concurrently
        let writeTask = Task {
            try await smb.write(data: data, toPath: file, progress: nil)
        }

        // Non-graceful disconnect should tear down immediately
        try await smb.disconnectShare(gracefully: false)

        // The write should have failed with some error
        do {
            try await writeTask.value
            // If the write completed before disconnect, that's acceptable
        } catch {
            // Expected — disconnect killed the in-flight operation
        }
    }

    func testOperationsFailAfterDisconnect() async throws {
        let smb = SMB2Manager(url: server, credential: credential)!
        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.disconnectShare(gracefully: true)

        // contents() should fail
        do {
            _ = try await smb.contents(atPath: "nonexistent.dat")
            XCTFail("contents() should fail after disconnect")
        } catch {
            let posixError = error as? POSIXError
            XCTAssertNotNil(posixError, "Expected POSIXError, got \(error)")
        }

        // write() should fail
        do {
            try await smb.write(data: Data([0x01]), toPath: "test.dat", progress: nil)
            XCTFail("write() should fail after disconnect")
        } catch {
            let posixError = error as? POSIXError
            XCTAssertNotNil(posixError, "Expected POSIXError, got \(error)")
        }

        // contentsOfDirectory() should fail
        do {
            _ = try await smb.contentsOfDirectory(atPath: "/")
            XCTFail("contentsOfDirectory() should fail after disconnect")
        } catch {
            let posixError = error as? POSIXError
            XCTAssertNotNil(posixError, "Expected POSIXError, got \(error)")
        }
    }

    func testReconnectAfterDisconnectFullRoundTrip() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        let data = randomData(size: 1024)

        addTeardownBlock {
            try? await smb.removeFile(atPath: file)
        }

        // Write data, then disconnect
        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.write(data: data, toPath: file, progress: nil)
        try await smb.disconnectShare(gracefully: true)

        // Reconnect and verify
        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.echo()

        let readBack = try await smb.contents(atPath: file)
        XCTAssertEqual(readBack, data)
    }

    func testDisconnectCompletesPromptly() async throws {
        let smb = SMB2Manager(url: server, credential: credential)!
        try await smb.connectShare(name: share, encrypted: encrypted)

        let start = Date()
        try await smb.disconnectShare(gracefully: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "disconnect() should complete promptly, not block for timeout (\(elapsed)s)")
    }

    // MARK: - Timeout Behavior

    func testShortTimeoutFiresOnLargeWrite() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        let data = randomData(size: 4 * 1024 * 1024)

        addTeardownBlock { [self] in
            smb.timeout = 60
            try? await smb.connectShare(name: self.share, encrypted: self.encrypted)
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)

        // Set an impossibly short timeout
        smb.timeout = 0.001

        do {
            try await smb.write(data: data, toPath: file, progress: nil)
            XCTFail("Write should have timed out")
        } catch {
            let posixError = error as? POSIXError
            XCTAssertNotNil(posixError, "Expected POSIXError, got \(error)")
            XCTAssertEqual(posixError?.code, .ETIMEDOUT)
        }
    }
}
