//
//  TestUtilities.swift
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

// MARK: - Shared Helpers

func randomData(size: Int) -> Data {
    Data((0..<size).map { _ in UInt8.random(in: 0...UInt8.max) })
}

func fileName(postfix: String = "", name: String = #function) -> String {
    "\(name.trimmingCharacters(in: .init(charactersIn: "()")))\(postfix).dat"
}

func folderName(postfix: String = "", name: String = #function) -> String {
    "\(name.trimmingCharacters(in: .init(charactersIn: "()")))\(postfix)"
}

// MARK: - Integration Test Base Class

class SMBIntegrationTestCase: XCTestCase, @unchecked Sendable {
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

    /// Transport selection for integration tests, driven by the `SMB_TRANSPORT` env var:
    /// - unset / `legacy` / unknown → `nil` (libsmb2-owned legacy TCP path)
    /// - `seam` / `tcp` / `auto` / `automatic` → `.automatic` (NIO TCP transport via the seam)
    ///
    /// Mirrors the `SMB_SERVER` convention so a single env flag flips a whole integration leg
    /// onto the seam. The default (unset) preserves the legacy path so existing tests are
    /// unaffected when the flag is absent.
    lazy var transportKind: SMBTransportKind? =
        Self.transportKind(forEnvValue: ProcessInfo.processInfo.environment["SMB_TRANSPORT"])

    /// `true` when the seam transport has been explicitly requested via `SMB_TRANSPORT`.
    var usesSeamTransport: Bool { transportKind != nil }

    /// Pure mapping from the `SMB_TRANSPORT` env value to a transport kind. Exposed (and
    /// `static`) so the mapping is unit-testable without manipulating the process environment.
    static func transportKind(forEnvValue value: String?) -> SMBTransportKind? {
        switch value?.lowercased() {
        case "seam", "tcp", "auto", "automatic":
            return .automatic
        default:
            return nil
        }
    }

    /// `host:port` string derived from `SMB_SERVER`, suitable for `SMB2Client.connect`.
    var serverHost: String {
        (server.host ?? "") + (server.port.map { ":\($0)" } ?? "")
    }

    /// Connects a raw `SMB2Client` honoring the active transport selection.
    ///
    /// On Apple the seam is the only client-level connect path (the legacy
    /// `connect(server:share:user:)` is compiled out), so an unset `transportKind` still routes
    /// through the seam via `.automatic`. On non-`Network` platforms (Linux) the legacy connect
    /// is used. Used by seam acceptance tests to assert transport-level invariants (e.g. the
    /// seam owns no native fd, so `fileDescriptor == -1`).
    func makeConnectedClient(toShare shareName: String? = nil) async throws -> SMB2Client {
        let client = try SMB2Client(timeout: 30)
        client.user = credential?.user ?? "guest"
        client.password = credential?.password ?? ""
        let targetShare = shareName ?? share
        #if canImport(Network)
        try await client.connect(
            server: serverHost, share: targetShare, user: client.user,
            transportKind: transportKind ?? .automatic
        )
        #else
        try await client.connect(server: serverHost, share: targetShare, user: client.user)
        #endif
        return client
    }

    /// Builds and connects an `SMB2Manager` to the configured share. On Apple the manager
    /// default is the seam (post-flip); on Linux it is the legacy path. The active transport is
    /// therefore the platform default — `transportKind` gates whether a seam leg runs, not which
    /// path the manager picks.
    func makeConnectedManager(encrypted overrideEncrypted: Bool? = nil) async throws -> SMB2Manager {
        let manager = try XCTUnwrap(SMB2Manager(url: server, credential: credential))
        try await manager.connectShare(name: share, encrypted: overrideEncrypted ?? encrypted)
        return manager
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SMB_SERVER"] != nil,
            "SMB server not configured"
        )
    }
}
