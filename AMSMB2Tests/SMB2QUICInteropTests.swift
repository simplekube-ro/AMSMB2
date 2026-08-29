//
//  SMB2QUICInteropTests.swift
//  AMSMB2
//
//  Created by Amir Abbas on 25/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

//
//  SMB2QUICInteropTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  LIVE SMB-over-QUIC interop tests (add-quic-transport tasks 4.2/4.3) against the standing rig
//  (Samba 4.23.6 + libquic on ubuntu-brix.kaveman.intra; see docs/INTEROP-QUIC.md). These are the
//  release gate: the first-contact NEGOTIATE round-trip is the D2 framing proof (libsmb2's
//  byte-stream reader requires the 4-byte direct-transport length prefix — a framing mismatch
//  cannot parse), and the matrix exercises auth, listing, large I/O, cancellation, the QUIC-only
//  failure mode, and the live TLS trust matrix.
//
//  **Deterministic skip on CI**: every test skips cleanly when `SMB_QUIC_SERVER` is unset, so the
//  no-env suite is unaffected. Apple-only (QUIC is `#if canImport(Network)`).
//
//  **Run in small `--filter` batches, not all 14 at once, against a userland-UDP-proxy rig**: the
//  reference rig publishes QUIC via docker's userland `docker-proxy` (`-p 443:443/udp`), which
//  wedges for new LAN flows under a sustained connect/disconnect burst — new connects then hang to
//  the connect deadline (`ETIMEDOUT`) even though the server is healthy (loopback smbclient keeps
//  working). This is a rig networking artifact, not an SMB/QUIC fault; see docs/INTEROP-QUIC.md
//  trap #5. All 14 tests pass individually / in small batches against the patched rig.
//  (A *TLS trust rejection* is no longer part of that symptom: it now fails fast with
//  `POSIXError(.EPROTO)`, so `ETIMEDOUT` here means only "endpoint unreachable/unresponsive".)
//
//  Env: SMB_QUIC_SERVER, SMB_QUIC_SHARE (default "share"), SMB_QUIC_USER (default "smbtest"),
//  SMB_QUIC_PASSWORD (default "quictest1"), SMB_QUIC_CA_DER (DER path of the lab CA),
//  SMB_QUIC_LEAF_DER (optional; DER path of the expected server leaf — enables the
//  certificate-probe fingerprint assertion).
//

#if canImport(Network)

import CryptoKit
import Foundation
import Security
import XCTest
@testable import AMSMB2

final class SMB2QUICInteropTests: XCTestCase, @unchecked Sendable {
    private var host = ""
    private var shareName = ""
    private var user = ""
    private var password = ""
    private var caDER = Data()

    /// Rig-specific real-media reference (overridable via env). See docs/INTEROP-QUIC.md.
    private var demoShare: String {
        env("SMB_QUIC_DEMO_SHARE") ?? "demo"
    }

    private var demoFile: String {
        env("SMB_QUIC_DEMO_FILE") ?? "Documentary/iss-earth.mp4"
    }

    private var demoMD5: String {
        env("SMB_QUIC_DEMO_MD5") ?? "ed7a9569933dcf5af07f2e60fa4e7256"
    }

    private func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let server = env("SMB_QUIC_SERVER") else {
            throw XCTSkip("SMB_QUIC_SERVER not set — QUIC interop tests skipped")
        }
        host = server
        shareName = env("SMB_QUIC_SHARE") ?? "share"
        user = env("SMB_QUIC_USER") ?? "smbtest"
        password = env("SMB_QUIC_PASSWORD") ?? "quictest1"
        guard let caPath = env("SMB_QUIC_CA_DER"),
              let der = try? Data(contentsOf: URL(fileURLWithPath: caPath))
        else {
            throw XCTSkip("SMB_QUIC_CA_DER not set or unreadable — QUIC interop tests skipped")
        }
        caDER = der
    }

    // MARK: - Helpers

    /// Builds a `.quic` manager for `host`/`share` with the given trust policy (default: the lab
    /// CA as a custom root). Does not connect.
    private func makeManager(
        host overrideHost: String? = nil,
        trustPolicy: SMBQUICConfiguration.TrustPolicy? = nil,
        connectTimeout: TimeInterval = 30
    ) throws -> SMB2Manager {
        let target = overrideHost ?? host
        let manager = try XCTUnwrap(SMB2Manager(
            url: XCTUnwrap(URL(string: "smb://\(target)")),
            credential: URLCredential(user: user, password: password, persistence: .forSession)
        ))
        manager.transportKind = .quic
        manager.quicConfiguration = SMBQUICConfiguration(
            trustPolicy: trustPolicy ?? .customRoots([caDER]), connectTimeout: connectTimeout
        )
        return manager
    }

    private func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Proves the rig is reachable and serving QUIC via a known-good `.customRoots` connect;
    /// `throw XCTSkip` if it can't. Still gates the trust-REJECTION tests: a trust rejection is now
    /// a distinct code (`.EPROTO`, never `.ETIMEDOUT`), but a down rig would make those tests skip
    /// on an unrelated failure or, worse, report a connect error unrelated to trust — the control
    /// keeps a rejection assertion meaningful.
    private func requireRigReachable() async throws {
        let control = try makeManager(trustPolicy: .customRoots([caDER]), connectTimeout: 15)
        do {
            try await control.connectShare(name: shareName)
            try? await control.disconnectShare()
        } catch {
            throw XCTSkip("rig unreachable (control connect failed: \(error)) — skipping rejection test")
        }
    }

    // MARK: - 4.2 First-contact gate (D2 framing proof)

    /// First contact: `.quic` + `customRoots([labCA])` completes the NEGOTIATE + session-setup
    /// handshake against `//host/share`. A successful handshake through libsmb2's byte-stream
    /// reader IS the D2 4-byte-framing proof — a framing mismatch could not parse NEGOTIATE.
    func testFirstContactNegotiateSucceeds() async throws {
        let manager = try makeManager()
        try await manager.connectShare(name: shareName)
        // A trivial post-handshake op confirms the session is live end-to-end.
        _ = try await manager.contentsOfDirectory(atPath: "/")
        try? await manager.disconnectShare()
    }

    // MARK: - 4.3 Matrix — auth / listing / large I/O

    /// NTLM auth + share enumeration over QUIC.
    func testShareEnumeration() async throws {
        let manager = try makeManager()
        try await manager.connectShare(name: shareName)
        let shares = try await manager.listShares()
        XCTAssertTrue(
            shares.contains { $0.name.lowercased() == shareName.lowercased() },
            "listShares over QUIC should include the connected share; got \(shares.map(\.name))"
        )
        try? await manager.disconnectShare()
    }

    /// Directory listing over QUIC.
    func testDirectoryListing() async throws {
        let manager = try makeManager()
        try await manager.connectShare(name: shareName)
        let entries = try await manager.contentsOfDirectory(atPath: "/")
        XCTAssertFalse(entries.isEmpty, "the share root should list at least one entry over QUIC")
        try? await manager.disconnectShare()
    }

    /// Large write + read-back integrity over QUIC (self-contained on the writable share).
    func testLargeWriteThenReadRoundTrip() async throws {
        let manager = try makeManager()
        try await manager.connectShare(name: shareName)

        let path = "amsmb2-quic-\(UUID().uuidString).bin"
        let payload = randomData(size: 8 * 1024 * 1024) // 8 MiB
        defer { Task { try? await manager.removeFile(atPath: path) } }

        try await manager.write(data: payload, toPath: path, progress: nil)
        let readBack: Data = try await manager.contents(atPath: path, range: 0..<UInt64(payload.count))
        XCTAssertEqual(readBack.count, payload.count, "read-back length must match the 8 MiB write")
        XCTAssertEqual(
            md5Hex(readBack), md5Hex(payload), "large write/read over QUIC must be byte-identical"
        )
    }

    /// Real-media read from `//demo` verified against the server-side md5 (integrity of a genuine
    /// server file over QUIC).
    func testRealMediaReadMatchesServerMD5() async throws {
        let manager = try makeManager()
        try await manager.connectShare(name: demoShare)
        let data: Data = try await manager.contents(atPath: demoFile)
        XCTAssertEqual(
            md5Hex(data), demoMD5,
            "real-media read over QUIC must match the server-side md5 of \(demoFile)"
        )
        try? await manager.disconnectShare()
    }

    /// Cancellation mid-transfer: a large read cancelled in flight does not hang and the manager
    /// stays usable. **Liveness/no-hang smoke only** — cancellation *correctness* (exactly-once
    /// resume, no leak, `CancellationError` vs mapped error) is proven deterministically in
    /// `QUICTransportAppleTests`; over a live server the cancel-vs-completion timing is racy, so
    /// this test only asserts the transfer terminates (a completed small/fast transfer is fine).
    func testCancelMidTransfer() async throws {
        let manager = try makeManager()
        try await manager.connectShare(name: demoShare)

        let readTask = Task { () -> Data in
            try await manager.contents(atPath: demoFile)
        }
        // Let the transfer start, then cancel it.
        try await Task.sleep(nanoseconds: 40_000_000) // 40 ms
        readTask.cancel()

        do {
            _ = try await readTask.value
            // A tiny/racy transfer may complete before the cancel lands — acceptable, not a failure.
        } catch {
            // Expected on a cancelled in-flight transfer (CancellationError or a mapped POSIXError).
        }
        try? await manager.disconnectShare()
    }

    /// Best-effort local disconnect completes cleanly (design D8 — server-side session teardown is
    /// observed out-of-band via `smbstatus`, not asserted as a guaranteed wire event here).
    func testBestEffortDisconnectCompletes() async throws {
        let manager = try makeManager()
        try await manager.connectShare(name: shareName)
        // Must return without throwing; wire delivery of DISCONNECT is best-effort (D8).
        try await manager.disconnectShare()
    }

    // MARK: - 4.3 Matrix — policy / failure modes

    /// Numeric target is rejected live with `EINVAL`, before any packet (one live sanity case;
    /// the classifier table is unit-proven).
    func testNumericTargetRejectedLive() async throws {
        // Resolve the rig's numeric address form is unnecessary — any numeric literal is rejected
        // in validation before a transport exists.
        let manager = try makeManager(host: "192.168.0.11")
        do {
            try await manager.connectShare(name: shareName)
            XCTFail("a numeric QUIC target must be rejected")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EINVAL, "numeric QUIC target must fail with EINVAL")
        }
    }

    /// QUIC-only failure mode: connecting `.quic` to a port with no QUIC listener surfaces a clean
    /// `POSIXError` (not a hang, not a silent success). This proves the failure *surfaces*; the
    /// **no-TCP-fallback** guarantee itself is architectural (the library has no fallback code
    /// path) and unit-covered by the `.quic` dispatch/policy tests — a live test cannot observe the
    /// absence of a fallback attempt, only that connect fails.
    func testQUICOnlyFailureModeNoFallback() async throws {
        let manager = try makeManager(host: "\(host):4443", connectTimeout: 6)
        do {
            try await manager.connectShare(name: shareName)
            XCTFail("connecting QUIC to a port with no QUIC listener must fail (no TCP fallback)")
        } catch let error as POSIXError {
            // ETIMEDOUT (deadline) or a mapped connection error — never a silent success.
            XCTAssertNotEqual(error.code, .EINVAL, "should be a connect-class failure, not validation")
        }
    }

    // MARK: - 4.3 Matrix — live TLS trust

    /// (a) Custom root + correct hostname → success. (Same as first contact; kept as the trust
    /// matrix's positive anchor.)
    func testTrustCustomRootCorrectHostSucceeds() async throws {
        let manager = try makeManager(trustPolicy: .customRoots([caDER]))
        try await manager.connectShare(name: shareName)
        try? await manager.disconnectShare()
    }

    /// (b) Custom root via the SAN-listed short name `ubuntu-brix` → success (alternate-correct
    /// hostname). Skips if the short name does not resolve from this host.
    func testTrustCustomRootShortNameSucceeds() async throws {
        let shortName = env("SMB_QUIC_SHORT_NAME") ?? "ubuntu-brix"
        let manager = try makeManager(host: shortName, trustPolicy: .customRoots([caDER]))
        do {
            try await manager.connectShare(name: shareName)
        } catch let error as POSIXError where error.code == .EHOSTUNREACH || error.code == .ENOENT {
            throw XCTSkip("short name \(shortName) did not resolve from this host")
        }
        try? await manager.disconnectShare()
    }

    /// (d) `.system` trust → REJECTED: the server certificate chains only to the lab CA, which is
    /// not in the system store, so the handshake fails — proving system-trust enforcement.
    func testTrustSystemRejectsLabCert() async throws {
        // A verify-failed QUIC handshake fails fast with `.EPROTO` (never the `.ETIMEDOUT`
        // deadline), so the code alone distinguishes a trust rejection from an unreachable rig.
        // The reachability control still runs so a down rig skips instead of asserting.
        try await requireRigReachable()
        let manager = try makeManager(trustPolicy: .system, connectTimeout: 8)
        let started = Date()
        do {
            try await manager.connectShare(name: shareName)
            XCTFail(".system trust must reject a cert that chains only to the lab CA")
        } catch {
            assertQUICTLSRejection(
                error, "system trust", elapsed: Date().timeIntervalSince(started)
            )
        }
    }

    /// (e) `.insecureNoVerification` → success (chain + hostname checks disabled; TLS + ALPN still
    /// required).
    func testTrustInsecureSucceeds() async throws {
        let manager = try makeManager(trustPolicy: .insecureNoVerification)
        try await manager.connectShare(name: shareName)
        try? await manager.disconnectShare()
    }

    /// (f) Custom root with an unrelated anchor → REJECTED (anchors replace system roots; the
    /// server cert does not chain to the supplied anchor).
    func testTrustUnrelatedAnchorRejected() async throws {
        guard let unrelated = Self.selfSignedDER(commonName: "unrelated.invalid") else {
            throw XCTSkip("openssl unavailable — cannot generate an unrelated anchor")
        }
        // See testTrustSystemRejectsLabCert: the rejection is `.EPROTO`, not the connect deadline;
        // a reachability control still gates the assertion against a down rig.
        try await requireRigReachable()
        let manager = try makeManager(trustPolicy: .customRoots([unrelated]), connectTimeout: 8)
        let started = Date()
        do {
            try await manager.connectShare(name: shareName)
            XCTFail("an unrelated custom anchor must reject the server certificate")
        } catch {
            assertQUICTLSRejection(
                error, "unrelated anchor", elapsed: Date().timeIntervalSince(started)
            )
        }
    }

    /// Asserts the live trust-rejection contract: `POSIXError(.EPROTO)` carrying the Security
    /// `OSStatus` as an `NSOSStatusErrorDomain` underlying error, so a caller can offer a
    /// "certificate not trusted" flow without parsing description text. The elapsed time is
    /// logged, not asserted — `.EPROTO` alone proves the non-deadline path (the deadline can only
    /// ever produce `.ETIMEDOUT`), and a wall-clock bound would only add flake on a loaded rig.
    private func assertQUICTLSRejection(
        _ error: any Error, _ label: String, elapsed: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let seconds = String(format: "%.3f", elapsed)
        print("QUIC trust rejection (\(label)) surfaced in \(seconds)s: \(error)")
        guard let posix = error as? POSIXError else {
            XCTFail("\(label): expected POSIXError(.EPROTO), got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(
            posix.code, .EPROTO, "\(label): a TLS rejection is EPROTO", file: file, line: line
        )
        let underlying = (posix as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        XCTAssertEqual(
            underlying?.domain, NSOSStatusErrorDomain,
            "\(label): the Security OSStatus must travel as an underlying error",
            file: file, line: line
        )
        XCTAssertNotEqual(
            underlying?.code ?? 0, 0,
            "\(label): the underlying OSStatus must be a real (non-zero) status",
            file: file, line: line
        )
    }

    // MARK: - Certificate probe (add-quic-certificate-probe, tasks 3.1–3.3)

    /// The probe returns the chain the rig actually presents, leaf first, with no SMB session
    /// created. `SMB_QUIC_LEAF_DER` (optional) pins the expected leaf by SHA-256 — the exact
    /// fingerprint a TOFU consumer would show a user before persisting the anchor.
    @available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
    func testProbeReturnsServerLeaf() async throws {
        let started = Date()
        let chain = try await SMBQUICCertificateProbe.fetchServerCertificateChain(server: host)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(chain.isEmpty, "the probe must return at least the leaf")
        let leaf = try XCTUnwrap(chain.first)
        XCTAssertNotNil(
            SecCertificateCreateWithData(nil, leaf as CFData),
            "the leaf must parse as a DER certificate"
        )
        print(
            "QUIC certificate probe: \(chain.count) DER(s) in "
                + String(format: "%.3f", elapsed) + "s; leaf SHA-256 " + sha256Hex(leaf)
        )
        for (index, der) in chain.enumerated() {
            print("  [\(index)] \(der.count) bytes, SHA-256 \(sha256Hex(der))")
        }

        guard let leafPath = env("SMB_QUIC_LEAF_DER"),
              let expectedLeaf = try? Data(contentsOf: URL(fileURLWithPath: leafPath))
        else { return }
        XCTAssertEqual(
            sha256Hex(leaf), sha256Hex(expectedLeaf),
            "the probed leaf must be the server's own certificate"
        )
        if expectedLeaf == caDER {
            XCTAssertEqual(
                chain.count, 1,
                "a self-signed target (leaf == CA) presents exactly one certificate"
            )
        }
    }

    /// The whole point of the probe: material it returns, fed back as `.customRoots`, connects.
    /// This is the trust-on-first-use round trip end to end.
    @available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
    func testProbedChainConnectsAsCustomRoots() async throws {
        let chain = try await SMBQUICCertificateProbe.fetchServerCertificateChain(server: host)
        XCTAssertFalse(chain.isEmpty, "nothing to anchor with")

        let manager = try makeManager(trustPolicy: .customRoots(chain))
        try await manager.connectShare(name: shareName)
        _ = try await manager.contentsOfDirectory(atPath: "/")
        try? await manager.disconnectShare()
    }

    /// A TCP-only port (445) answers nothing on UDP, so the probe must hit its own deadline and
    /// return promptly — never hang past `timeout` plus teardown.
    @available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
    func testProbeAgainstTCPOnlyPortDoesNotHang() async throws {
        let started = Date()
        do {
            _ = try await SMBQUICCertificateProbe.fetchServerCertificateChain(
                server: "\(host):445", timeout: 3
            )
            XCTFail("a TCP-only port must not yield a QUIC certificate chain")
        } catch let posix as POSIXError {
            let elapsed = Date().timeIntervalSince(started)
            print(
                "QUIC probe against \(host):445 → \(posix.code) in "
                    + String(format: "%.3f", elapsed) + "s"
            )
            XCTAssertTrue(
                [.ETIMEDOUT, .EPROTO].contains(posix.code),
                "expected ETIMEDOUT or EPROTO, got \(posix.code)"
            )
            XCTAssertLessThan(elapsed, 5, "the probe must return within timeout plus teardown")
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 4.3 D8 lifecycle observations (opt-in; set SMB_QUIC_OBSERVE=1)

    // These make and RECORD the D8 server-side observations (best-effort disconnect teardown;
    // server-initiated close shape). They are opt-in (extra `SMB_QUIC_OBSERVE` gate) and
    // self-coordinate with the rig over ssh, so they never run in a normal interop pass. Findings
    // are transcribed into docs/INTEROP-QUIC.md.

    /// Observes server-side session teardown after a best-effort local `disconnect()` (design D8):
    /// captures `smbstatus` with the session live, disconnects, and polls until the session
    /// disappears, recording the teardown latency.
    func testObserveDisconnectServerTeardown() async throws {
        try XCTSkipUnless(env("SMB_QUIC_OBSERVE") != nil, "opt-in D8 observation")
        let manager = try makeManager()
        try await manager.connectShare(name: shareName)
        _ = try await manager.contentsOfDirectory(atPath: "/") // establish a live session

        let live = Self.ssh("docker exec samba-quic /opt/samba/bin/smbstatus")
        print("D8-OBSERVE live-session smbstatus:\n\(live)")
        // Fail-safe (like the server-close sibling): if the ssh/smbstatus probe returns nothing,
        // the rig is unreachable/misconfigured for this observation — skip, don't hard-fail.
        try XCTSkipUnless(!live.isEmpty, "ssh/smbstatus probe returned empty — cannot observe")
        XCTAssertTrue(
            live.lowercased().contains(user.lowercased()),
            "expected a live session for \(user) in smbstatus"
        )

        let start = Date()
        try await manager.disconnectShare()
        var teardownLatency = -1.0
        for _ in 0..<40 {
            let status = Self.ssh("docker exec samba-quic /opt/samba/bin/smbstatus")
            if !status.lowercased().contains(user.lowercased()) {
                teardownLatency = Date().timeIntervalSince(start)
                print("D8-OBSERVE after-disconnect smbstatus:\n\(status)")
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        print("D8-OBSERVE disconnect->teardown latency seconds: \(teardownLatency)")
    }

    /// Observes what a server-initiated close looks like to our client (design D8): establishes a
    /// session, restarts the server mid-session, and records whether the next operation surfaces a
    /// graceful EOF-derived error or abnormal loss. Pure observation (no assertion). Self-heals —
    /// `docker restart` brings the rig back.
    func testObserveServerInitiatedClose() async throws {
        try XCTSkipUnless(env("SMB_QUIC_OBSERVE") != nil, "opt-in D8 observation")
        let manager = try makeManager(connectTimeout: 20)
        manager.timeout = 8 // fail the post-close op fast rather than at the default 60 s
        try await manager.connectShare(name: shareName)
        _ = try await manager.contentsOfDirectory(atPath: "/")

        print("D8-OBSERVE restarting server mid-session…")
        _ = Self.ssh("docker restart samba-quic") // SIGTERM smbd → server-side close, then back up

        do {
            _ = try await manager.contentsOfDirectory(atPath: "/")
            print("D8-OBSERVE server-close: next op SUCCEEDED (auto-reconnect or race)")
        } catch let error as POSIXError {
            print("D8-OBSERVE server-close: next op threw POSIXError .\(error.code) — \((error as NSError).localizedDescription)")
        } catch {
            print("D8-OBSERVE server-close: next op threw \(type(of: error)): \(error)")
        }

        // Wait for the rig to be healthy again before yielding the shared rig.
        for _ in 0..<20 {
            if Self
                .ssh(
                    "docker exec samba-quic /opt/samba/bin/smbclient //localhost/share -U \(user)%\(password) -s /rig/smb.conf --option=client\\ smb\\ transports=quic --option=tls\\ verify\\ peer\\ =\\ ca_and_name -c ls"
                )
                .contains("blocks of size")
            {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Runs `ssh <SMB_QUIC_SERVER> <command>` and returns combined stdout (best-effort; empty on
    /// failure). Used only by the opt-in observation tests above.
    private static func ssh(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
            ProcessInfo.processInfo.environment["SMB_QUIC_SERVER"] ?? "", command,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "<ssh spawn failed: \(error)>" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Test cert generation (unrelated anchor)

    /// Generates a temporally-valid self-signed leaf DER via `openssl`, or `nil` if unavailable.
    private static func selfSignedDER(commonName: String) -> Data? {
        let directory = FileManager.default.temporaryDirectory
        let base = directory.appendingPathComponent("amsmb2-quic-interop-\(UUID().uuidString)")
        let keyPath = base.appendingPathExtension("key").path
        let pemPath = base.appendingPathExtension("pem").path
        defer {
            try? FileManager.default.removeItem(atPath: keyPath)
            try? FileManager.default.removeItem(atPath: pemPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath, "-out", pemPath, "-days", "300",
            "-subj", "/CN=\(commonName)",
            "-addext", "subjectAltName=DNS:\(commonName)",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "extendedKeyUsage=serverAuth",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let pem = try? String(contentsOfFile: pemPath, encoding: .utf8),
              let beginRange = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let endRange = pem.range(
                  of: "-----END CERTIFICATE-----", range: beginRange.upperBound..<pem.endIndex
              )
        else { return nil }
        let body = pem[beginRange.upperBound..<endRange.lowerBound]
            .split(whereSeparator: \.isNewline).joined()
        return Data(base64Encoded: body)
    }
}

#endif // canImport(Network)
