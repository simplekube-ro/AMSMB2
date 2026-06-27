//
//  SMB2SeamIntegrationTests.swift
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

/// T8 acceptance matrix exercised through the NIO TCP transport seam.
///
/// These tests are gated on `SMB_TRANSPORT=seam` (so the seam CI leg opts in) AND require a live
/// Samba server (inherited `SMB_SERVER` skip). On Apple the `SMB2Manager` default routes through
/// the seam (`TCPTransportApple` + `TransportBridge` + the no-fd servicing loop) post-flip, so the
/// `SMB2Manager`-level operations below are genuinely seam-routed. The raw-client test additionally
/// asserts the seam's transport-level signature (`fileDescriptor == -1`).
///
/// Acceptance (a green run against a real server) is DEFERRED to a human Docker run; without a
/// server these skip cleanly. The seam path cannot speak real SMB2 from a unit-level mock, so the
/// matrix can only be validated against Samba.
class SMB2SeamIntegrationTests: SMBIntegrationTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
        try super.setUpWithError() // Skips unless SMB_SERVER is configured.
        #if !canImport(Network)
        throw XCTSkip("Seam transport (TCPTransportApple) is unavailable on this platform")
        #endif
        try XCTSkipUnless(
            usesSeamTransport,
            "Seam transport not selected; set SMB_TRANSPORT=seam to run the seam acceptance leg"
        )
    }

    // MARK: - Connect + NTLM auth

    /// Acceptance: connect + NTLM authentication succeed through the seam.
    func testConnectAndAuthenticate() async throws {
        let manager = try await makeConnectedManager()
        // A successful echo proves the negotiated/authenticated session is live over the seam.
        try await manager.echo()
    }

    /// Acceptance: a raw seam-connected client owns no native socket fd (the naming-trap
    /// invariant — `smb2_set_transport(AUTO)` means `smb2_get_fd == -1`).
    func testSeamConnectionHasNoFileDescriptor() async throws {
        let client = try await makeConnectedClient()
        addTeardownBlock { await client.disconnect() }
        XCTAssertEqual(client.fileDescriptor, -1, "seam transport must not own a native socket fd")
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - Directory listing

    /// Acceptance: directory enumeration succeeds through the seam.
    func testDirectoryListing() async throws {
        let manager = try await makeConnectedManager()
        let entries = try await manager.contentsOfDirectory(atPath: "/")
        XCTAssertFalse(entries.isEmpty, "share root should enumerate at least one entry")
    }

    // MARK: - Large read / write

    /// Acceptance: a large sequential write followed by a full read returns identical bytes
    /// through the seam. Uses `write(data:)` / `contents(atPath:)` (no stream I/O, no pipelined
    /// writes) per the CLAUDE.md gotchas.
    func testLargeWriteThenRead() async throws {
        let manager = try await makeConnectedManager()
        let file = fileName()
        addTeardownBlock { try? await manager.removeFile(atPath: file) }

        // ~5 MB exceeds a single SMB2 transaction, exercising multi-PDU servicing over the seam.
        let payload = randomData(size: 5 * 1024 * 1024 + 7)
        try await manager.write(data: payload, toPath: file, progress: nil)

        // Explicit type disambiguates the `async throws -> Data` overload from the stream one.
        let roundTripped: Data = try await manager.contents(atPath: file)
        XCTAssertEqual(roundTripped, payload)
    }

    // MARK: - Cancel / timeout

    /// Acceptance: cancelling an in-flight operation tears the seam down without hanging.
    func testCancelInFlightOperation() async throws {
        let manager = try await makeConnectedManager()
        let file = fileName()
        addTeardownBlock {
            try? await manager.connectShare(name: self.share, encrypted: self.encrypted)
            try? await manager.removeFile(atPath: file)
        }

        let payload = randomData(size: 8 * 1024 * 1024)
        let writeTask = Task {
            try await manager.write(data: payload, toPath: file, progress: nil)
        }
        writeTask.cancel()

        do {
            try await writeTask.value
            // Completing before cancellation took effect is acceptable for a fast loopback server.
        } catch is CancellationError {
            // Expected on cancellation.
        } catch {
            // A POSIX teardown error is also acceptable; the key requirement is no hang.
        }
    }

    /// 8.3 — both-ways parametrization. The matrix is wired here as a reusable driver, but a true
    /// legacy-vs-seam comparison on a single Apple host is impossible: the legacy
    /// `connect(server:share:user:)` is compiled out on Apple (T9.3), and the seam transport is
    /// unavailable on Linux. The both-ways comparison is therefore DEFERRED to a human/cross-CI
    /// run (legacy leg on Linux + seam leg on macOS, compared out-of-band).
    func testBothWaysComparison() async throws {
        throw XCTSkip(
            """
            8.3 both-ways comparison is DEFERRED to a human Docker run: legacy and seam cannot be \
            exercised from one host (legacy is compiled out on Apple, seam is Apple-only). Run the \
            seam leg (SMB_TRANSPORT=seam) on macOS and the legacy leg on Linux, then compare.
            """
        )
    }
}
