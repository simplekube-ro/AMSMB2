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

class SMB2DisconnectTimeoutTests: SMBIntegrationTestCase, @unchecked Sendable {

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

    /// WHEN a non-graceful `disconnectShare` happens while a large read is in flight against a
    /// real server
    /// THEN the client is deallocated once the read's failure has been observed and the live
    /// callback-object count returns to its baseline.
    ///
    /// This is the pool-teardown scenario from GitHub issue #49: before
    /// fix-disconnect-reclaims-context, `disconnect()` left the pending read's `CBData` registered
    /// with libsmb2, and the `CBData.dataHandler` wrapper's strong `self` capture made the whole
    /// client — context, event-loop queue, buffers — unreclaimable forever.
    ///
    /// `smb.timeout = 3` bounds the per-operation timer that captures the (already emptied)
    /// `CBData` strongly, so the `liveCount` poll below has a deterministic upper bound.
    func testNonGracefulDisconnectMidReadReleasesClient() async throws {
        let file = fileName()
        let smb = SMB2Manager(url: server, credential: credential)!
        // 32 MiB, not 4: the read must still be in flight when the disconnect lands, otherwise
        // nothing is pending and the test would pass even against the unfixed code.
        let data = randomData(size: 32 * 1024 * 1024)

        addTeardownBlock { [self] in
            smb.timeout = 60
            try? await smb.connectShare(name: self.share, encrypted: self.encrypted)
            try? await smb.removeFile(atPath: file)
        }

        try await smb.connectShare(name: share, encrypted: encrypted)
        try await smb.write(data: data, toPath: file, progress: nil)

        let baseline = SMB2Client.CBData.liveCount
        smb.timeout = 3

        let readTask = Task {
            try await smb.contents(atPath: file, progress: nil)
        }

        // `weak var` + separate assignment: `weak let` needs Swift 6.2, and the Linux image
        // (`Dockerfile`: swift:6.1) rejects it; a never-mutated `weak var` warns on 6.2.
        weak var weakClient: SMB2Client?
        do {
            // Scoped: the test's own strong reference must be gone before the release check.
            let client = try smb.smbClient
            weakClient = client
            // "In flight" means an operation is registered with libsmb2 and unanswered. A
            // progress callback is NOT that signal: the read loop pipelines 4 × `optimizedReadSize`
            // (8 MiB against Samba) per window, so a 32 MiB file completes in ONE window and the
            // first progress call would only fire after the whole file had arrived.
            let inFlight = await waitUntil(timeout: 20) { client.pendingSeamOperationCount > 0 }
            XCTAssertTrue(inFlight, "no operation became pending before the deadline")
        }

        try await smb.disconnectShare(gracefully: false)

        var readFailed = false
        do {
            _ = try await readTask.value
        } catch {
            // Expected — the disconnect failed the in-flight read.
            readFailed = true
        }
        XCTAssertTrue(
            readFailed,
            "read completed before the disconnect landed — the mid-read scenario was not exercised"
        )

        // The per-operation timeout timer holds the emptied CBData shell for up to `timeout`
        // seconds even after the fix, so wait rather than asserting instantly. `<=`, not `==`:
        // the count is process-global and other suites can drop below this baseline meanwhile.
        let reclaimed = await waitUntil(timeout: 8) { SMB2Client.CBData.liveCount <= baseline }
        XCTAssertTrue(
            reclaimed,
            "disconnect() must reclaim every pending callback object "
                + "(live count \(SMB2Client.CBData.liveCount), baseline \(baseline))"
        )

        let released = await waitUntil(timeout: 2) { weakClient == nil }
        XCTAssertTrue(released, "a non-graceful disconnect mid-read must not leave the client alive")
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
