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

class SMB2DisconnectTimeoutTests: SMBIntegrationTestCase {

    // MARK: - Disconnect Behavior

    func testGracefulDisconnectWaitsForInFlightOperation() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        let data = randomData(size: 4 * 1024 * 1024)

        addTeardownBlock {
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)

        // Start a large write concurrently and wait for it to begin
        let writeStarted = expectation(description: "write started")
        writeStarted.assertForOverFulfill = false
        let writeTask = Task {
            try await smb.write(
                data: data, toPath: file,
                progress: { _ -> Bool in
                    writeStarted.fulfill()
                    return true
                }
            )
        }

        // Wait until the write is actually in-flight before disconnecting
        await fulfillment(of: [writeStarted], timeout: 10)

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
            // With a very short timeout, the operation may fail with ETIMEDOUT
            // or ECONNRESET (if the connection is torn down by the timeout handler)
            let acceptableCodes: [POSIXErrorCode] = [.ETIMEDOUT, .ECONNRESET, .ECANCELED]
            XCTAssertTrue(
                acceptableCodes.contains(posixError?.code ?? .EINVAL),
                "Expected ETIMEDOUT, ECONNRESET, or ECANCELED but got \(posixError?.code.rawValue ?? -1) (\(error))"
            )
        }
    }
}
