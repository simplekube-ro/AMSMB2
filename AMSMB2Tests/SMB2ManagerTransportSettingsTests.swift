//
//  SMB2ManagerTransportSettingsTests.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest
#if canImport(ObjectiveC)
import ObjectiveC
#endif

@testable import AMSMB2

final class SMB2ManagerTransportSettingsTests: XCTestCase, @unchecked Sendable {
    private func makeManager(host: String = "server.example") -> SMB2Manager {
        SMB2Manager(url: URL(string: "smb://\(host)/share")!, credential: nil)!
    }

    // MARK: - 3.1 Properties + snapshot semantics (design D6)

    /// Defaults: `transportKind` is `.automatic`, `quicConfiguration` is `nil`.
    func testDefaults() {
        let manager = makeManager()
        XCTAssertEqual(manager.transportKind, .automatic)
        XCTAssertNil(manager.quicConfiguration)
    }

    /// The properties round-trip through their (lock-guarded) accessors.
    func testGetSetRoundTrip() {
        let manager = makeManager()
        manager.transportKind = .quic
        let config = SMBQUICConfiguration(trustPolicy: .insecureNoVerification, connectTimeout: 7)
        manager.quicConfiguration = config
        XCTAssertEqual(manager.transportKind, .quic)
        XCTAssertEqual(manager.quicConfiguration, config)
    }

    /// The connect snapshot is an immutable value copy: mutating the properties AFTER taking a
    /// snapshot does not change the already-taken snapshot (so an in-flight connect is unaffected).
    func testTransportSnapshotIsImmutableValueCopy() {
        let manager = makeManager()
        manager.transportKind = .quic
        manager.quicConfiguration = SMBQUICConfiguration(connectTimeout: 5)

        let snapshot = manager.transportSnapshot()
        manager.transportKind = .automatic // mutate after the snapshot.
        manager.quicConfiguration = nil

        XCTAssertEqual(snapshot.kind, .quic, "snapshot kind must not change after later mutation")
        XCTAssertEqual(snapshot.quic?.connectTimeout, 5, "snapshot config must be a value copy")
    }

    // MARK: - 3.2 Codable (private string mapping; quic never serialized)

    /// Codable round-trip: `transportKind` survives; `quicConfiguration` is NOT serialized (a
    /// decoded `.quic` manager gets the system-trust default — `nil`).
    func testCodableRoundTripOmitsQUICConfiguration() throws {
        let manager = makeManager()
        manager.transportKind = .quic
        manager.quicConfiguration = SMBQUICConfiguration(
            trustPolicy: .customRoots([Data([0x30])]), connectTimeout: 12
        )

        let data = try JSONEncoder().encode(manager)
        let decoded = try JSONDecoder().decode(SMB2Manager.self, from: data)

        XCTAssertEqual(decoded.transportKind, .quic)
        XCTAssertNil(decoded.quicConfiguration, "quicConfiguration must never be serialized")
    }

    /// Each kind round-trips through the private string mapping.
    func testCodableRoundTripAllKinds() throws {
        for kind in [SMBTransportKind.tcp, .quic, .automatic] {
            let manager = makeManager()
            manager.transportKind = kind
            let data = try JSONEncoder().encode(manager)
            let decoded = try JSONDecoder().decode(SMB2Manager.self, from: data)
            XCTAssertEqual(decoded.transportKind, kind)
        }
    }

    /// Old archives (created before this change — no `transportKind` key) decode to `.automatic`.
    func testCodableOldArchiveDecodesToAutomatic() throws {
        let json = """
        {"url":"smb://server.example/share","domain":"","workstation":"","user":"guest",\
        "password":"","timeout":60}
        """
        let decoded = try JSONDecoder().decode(SMB2Manager.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transportKind, .automatic, "missing key must decode to .automatic")
    }

    /// An unknown `transportKind` token decodes to `.automatic` (locks the `default` branch of
    /// the private string mapping, so a future/foreign token never fails or mis-decodes).
    func testCodableUnknownTokenDecodesToAutomatic() throws {
        let json = """
        {"url":"smb://server.example/share","domain":"","workstation":"","user":"guest",\
        "password":"","timeout":60,"transportKind":"bogus"}
        """
        let decoded = try JSONDecoder().decode(SMB2Manager.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transportKind, .automatic, "unknown token must decode to .automatic")
    }

    // MARK: - 3.2 Copying (design D6)

    /// `copy(with:)` preserves value snapshots of BOTH settings — never a silent revert to
    /// `.automatic` — and the copy is unaffected by later mutation of the original.
    func testCopyPreservesSettingsAndIsIndependent() throws {
        let manager = makeManager()
        manager.transportKind = .quic
        manager.quicConfiguration = SMBQUICConfiguration(connectTimeout: 9)

        let copy = try XCTUnwrap(manager.copy() as? SMB2Manager)
        XCTAssertEqual(copy.transportKind, .quic)
        XCTAssertEqual(copy.quicConfiguration?.connectTimeout, 9)

        // Mutating the original after copy must not change the copy (value snapshot).
        manager.transportKind = .automatic
        manager.quicConfiguration = nil
        XCTAssertEqual(copy.transportKind, .quic, "copy must be an independent value snapshot")
        XCTAssertEqual(copy.quicConfiguration?.connectTimeout, 9)
    }

    // MARK: - 3.2 NSSecureCoding (Apple-only — NSKeyedUnarchiver differs on Linux)

#if canImport(Darwin)
    func testSecureCodingRoundTripOmitsQUICConfiguration() throws {
        let manager = makeManager()
        manager.transportKind = .quic
        manager.quicConfiguration = SMBQUICConfiguration(connectTimeout: 11)

        let data = try NSKeyedArchiver.archivedData(
            withRootObject: manager, requiringSecureCoding: true
        )
        let decoded = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: SMB2Manager.self, from: data
        )

        XCTAssertEqual(decoded?.transportKind, .quic)
        XCTAssertNil(decoded?.quicConfiguration, "quicConfiguration must never be serialized")
    }

    /// An NSSecureCoding archive without the `transportKind` key (old format) decodes to
    /// `.automatic`. Built manually to omit the key.
    func testSecureCodingOldArchiveDecodesToAutomatic() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        try archiver.encode(XCTUnwrap(URL(string: "smb://server.example/share")) as NSURL, forKey: "url")
        archiver.encode("" as NSString, forKey: "domain")
        archiver.encode("" as NSString, forKey: "workstation")
        archiver.encode("guest" as NSString, forKey: "user")
        archiver.encode("" as NSString, forKey: "password")
        archiver.encode(60.0, forKey: "timeout")
        // Intentionally NO "transportKind" key (simulating a pre-change archive).
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        let decoded = SMB2Manager(coder: unarchiver)
        XCTAssertEqual(decoded?.transportKind, .automatic, "missing key must decode to .automatic")
    }
#endif

    // MARK: - 3.3 Swift-only Objective-C posture (design D11) — Apple-only

#if canImport(Darwin)
    /// The new members are Swift-only: `SMBTransportKind`/`SMBQUICConfiguration` are not
    /// Objective-C-representable and `SMB2Manager` is not `@objcMembers`, so the compiler cannot
    /// infer `@objc` for them — they must be absent from the generated Objective-C interface.
    /// Verified at runtime via the Objective-C metadata (this executes in the test suite).
    func testNewSurfaceAbsentFromObjCInterface() {
        for selectorName in ["transportKind", "setTransportKind:", "quicConfiguration", "setQuicConfiguration:"] {
            XCTAssertFalse(
                SMB2Manager.instancesRespond(to: NSSelectorFromString(selectorName)),
                "\(selectorName) must not be exposed to Objective-C"
            )
        }
        XCTAssertNil(
            class_getProperty(SMB2Manager.self, "transportKind"),
            "transportKind must not be an Objective-C property"
        )
        XCTAssertNil(
            class_getProperty(SMB2Manager.self, "quicConfiguration"),
            "quicConfiguration must not be an Objective-C property"
        )

        // SMBQUICConfiguration is a struct; QUICTransportApple is a pure Swift class — neither can
        // appear in the Objective-C interface.
        XCTAssertFalse(
            SMBQUICConfiguration.self is AnyClass,
            "SMBQUICConfiguration is a struct — never Objective-C-representable"
        )
#if canImport(Network)
        if #available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *) {
            XCTAssertFalse(
                QUICTransportApple.self is NSObject.Type,
                "QUICTransportApple must not be an Objective-C/NSObject class"
            )
        }
#endif
    }

    /// The pre-existing Objective-C entry points remain exposed (the ObjC compat surface is
    /// source-compatible and unchanged).
    func testExistingObjCSelectorsPreserved() {
        for selectorName in [
            "connectShareWithName:completionHandler:",
            "connectShareWithName:encrypted:completionHandler:",
            "disconnectShare",
            "echoWithCompletionHandler:",
            "url",
            "timeout",
        ] {
            XCTAssertTrue(
                SMB2Manager.instancesRespond(to: NSSelectorFromString(selectorName)),
                "pre-existing @objc selector \(selectorName) must remain exposed"
            )
        }
    }
#endif

    // MARK: - 3.4 Linux routing (design D6) — Linux-only

#if !canImport(Network)
    /// On Linux, `.quic` is rejected with the `ENOTSUP` errno (which the `POSIXErrorCode` bridge
    /// represents as `.EOPNOTSUPP` — ENOTSUP == EOPNOTSUPP on Linux) before any transport
    /// construction or network activity — never a silent downgrade.
    func testLinuxQuicThrowsENOTSUP() async {
        let manager = makeManager(host: "nonexistent.invalid")
        manager.transportKind = .quic
        do {
            try await manager.connectShare(name: "share")
            XCTFail(".quic on Linux must throw ENOTSUP")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EOPNOTSUPP, ".quic on Linux must be ENOTSUP/EOPNOTSUPP")
        } catch {
            XCTFail("expected POSIXError(ENOTSUP), got \(error)")
        }
    }

    /// On Linux, `.tcp`/`.automatic` take the legacy libsmb2-owned path — they do NOT hit the
    /// QUIC reject (they fail later, at the connect to an unresolvable host, with a non-ENOTSUP
    /// error), proving the routing chose the legacy path.
    func testLinuxTcpAndAutomaticUseLegacyPath() async {
        for kind in [SMBTransportKind.tcp, .automatic] {
            let manager = makeManager(host: "nonexistent.invalid")
            manager.transportKind = kind
            manager.timeout = 2
            do {
                try await manager.connectShare(name: "share")
                XCTFail("connect to an unresolvable host should fail")
            } catch let error as POSIXError {
                XCTAssertNotEqual(
                    error.code, .EOPNOTSUPP,
                    "\(kind) must take the legacy path, not the QUIC reject"
                )
            } catch {
                // Any non-POSIXError is also acceptable — it proves the legacy path ran.
            }
        }
    }
#endif
}
