//
//  SMBQUICCertificateProbe.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation
#if canImport(Glibc)
import Glibc // `ENOTSUP` errno constant for the Linux body.
#endif
#if canImport(Network)

/// A lock-guarded holder for the DER chain the capture verify block observed — the most recent
/// non-empty chain wins (design D2).
///
/// `@unchecked Sendable` because it crosses isolation boundaries by design: it is written from
/// the driver's private `verifyQueue`, captured by the probe's driver-factory closure, and read
/// by the probe after `await close()` — the `NSLock` supplies the memory barrier for that
/// cross-queue handoff. Deliberately has no back-reference to the driver or the probe, so a
/// late-firing verify block after the probe returned writes to an orphan and is dropped.
final class QUICCertificateCaptureSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var _chain: [Data]?

    /// Records the presented chain. Called from the verify block before it rejects the handshake.
    ///
    /// An empty chain is *not* a capture: it is what `certificateChainDER` yields when
    /// Security.framework handed the verify block no certificates, and storing it would turn
    /// "nothing captured" into a bogus success. Ignoring it here keeps the invariant in one place
    /// — a stored chain is always non-empty — and leaves any earlier capture intact.
    func store(_ chain: [Data]) {
        guard !chain.isEmpty else { return } // an empty chain is "nothing captured" (design D1: the EPROTO row)
        lock.withLock { _chain = chain }
    }

    /// The captured chain, or `nil` if nothing was ever captured.
    var chain: [Data]? {
        lock.withLock { _chain }
    }
}

#endif // canImport(Network)

/// Retrieves the certificate chain an SMB-over-QUIC server presents, **without ever trusting it**
/// and without creating an SMB session — the building block for a trust-on-first-use flow
/// (show subject / SAN / validity / SHA-256, let the user confirm, then persist the DER as an
/// `SMBQUICConfiguration.TrustPolicy.customRoots` anchor).
///
/// Swift-only; there is no Objective-C entry point (as for the rest of the QUIC surface).
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
public enum SMBQUICCertificateProbe {
    /// Performs exactly one SMB-over-QUIC TLS handshake (ALPN `"smb"`, SNI = host, TLS 1.3)
    /// against `server`, captures the certificate chain the server presents, and then **always**
    /// rejects the handshake — no code path completes verification successfully, so the
    /// connection is torn down before any application data is exchanged. No SMB PDU is ever sent,
    /// no SMB session is created, and the connection never outlives this call: on every exit path
    /// a connection that was started is cancelled exactly once before the call returns.
    ///
    /// - Parameters:
    ///   - server: the target as `host[:port]` — for example `"fs.example.com"` (UDP/443, the
    ///     SMB-over-QUIC default) or `"fs.example.com:4433"` (an explicit port, honored verbatim).
    ///     The host must be a name: a numeric IPv4/IPv6 address or an empty host is rejected with
    ///     `POSIXError(.EINVAL)`, exactly as a `.quic` connect rejects it, and an explicit port
    ///     outside `1...65535` is rejected the same way.
    ///   - timeout: the handshake deadline in seconds, default `8`. It is **independent** of
    ///     `SMB2Manager.timeout` and of `SMBQUICConfiguration.connectTimeout` (which defaults to
    ///     30 s): a probe is interactive — a person is waiting on a "fetch certificate" button —
    ///     while a connect deadline covers an unattended session setup. `NaN`, infinite, zero,
    ///     and negative values throw `POSIXError(.EINVAL)`; values above 3600 s clamp to 3600.
    ///
    /// - Returns: the DER-encoded chain **leaf first**, as presented to Security.framework
    ///   (against a publicly-trusted server the platform may append a root the server did not
    ///   send; for the self-signed and private-CA servers this API exists for, it is exactly what
    ///   the peer sent).
    ///
    /// - Throws:
    ///   - `POSIXError(.EINVAL)` — invalid `server` or `timeout`, thrown before any network
    ///     activity.
    ///   - `POSIXError(.EPROTO)` — the handshake failed for a TLS reason before any certificate
    ///     was delivered (ALPN mismatch, no QUIC listener that still answers TLS, …), carrying
    ///     the Security `OSStatus` as an `NSOSStatusErrorDomain` error under
    ///     `NSUnderlyingErrorKey`; also thrown if the handshake completed and yet nothing was
    ///     captured.
    ///   - `POSIXError(.ETIMEDOUT)` — the endpoint was unreachable or unresponsive within
    ///     `timeout`. If a chain was already captured when the deadline expired, the chain is
    ///     returned instead.
    ///   - `CancellationError` — the calling task was cancelled; this propagates whenever the
    ///     handshake was still in flight when cancellation was observed, even if a chain had
    ///     already been captured — a cancelled task never observes a success value. A cancellation
    ///     that lands after the handshake outcome was reported does not retroactively discard the
    ///     result.
    ///   - `POSIXError(.ENOTSUP)` — on platforms without Network.framework (Linux), thrown
    ///     before any network activity.
    ///
    /// - Important: first contact is only as trustworthy as the network at that moment. The probe
    ///   never trusts the peer — the user does. An on-path attacker can present their own chain,
    ///   so the returned leaf's SHA-256 must be confirmed out of band before it is persisted as a
    ///   `.customRoots` anchor (which *replaces* the system roots for that connection).
    public static func fetchServerCertificateChain(
        server: String, timeout: TimeInterval = 8
    ) async throws -> [Data] {
        #if canImport(Network)
        try await fetchServerCertificateChain(
            server: server, timeout: timeout,
            driverFactory: { host, port, slot in
                NWConnectionQUICDriver(host: host, port: port, trust: .capture(slot))
            },
            deadline: DispatchDeadlineScheduler()
        )
        #else
        // No Network.framework: reject before any validation or network activity, with the same
        // spelling as `SMB2Manager.connectShare`'s up-front `.quic` rejection. `.ENOTSUP` is not
        // a `POSIXErrorCode` case on Linux; bridge the C `ENOTSUP` errno (== `EOPNOTSUPP` there)
        // through the numeric initializer for a portable code.
        throw POSIXError(.init(ENOTSUP),
            description: "SMB over QUIC is not supported on this platform")
        #endif
    }

    #if canImport(Network)
    /// Test entry point mirroring `QUICTransportApple`'s injected seams (design D6): a
    /// probe-specific driver factory that receives the capture slot, plus a
    /// `ConnectDeadlineScheduler` that fires on demand. Not part of the public surface.
    ///
    /// Implements the D1 outcome table: validate → connect → **always** `await close()` → read
    /// the slot → classify. `CancellationError` always propagates; otherwise a captured chain
    /// wins over any error; otherwise the transport's error is the probe's error.
    static func fetchServerCertificateChain(
        server: String, timeout: TimeInterval,
        driverFactory: @escaping (_ host: String, _ port: Int, _ slot: QUICCertificateCaptureSlot)
            -> any QUICConnectionDriver,
        deadline: any ConnectDeadlineScheduler
    ) async throws -> [Data] {
        // Validation first: both helpers throw `EINVAL` before a slot, a transport, or a driver
        // can exist, so an invalid target performs no network activity at all.
        let endpoint = try SMB2Client.validatedQUICEndpoint(server)
        let connectTimeout = try SMB2Client.normalizedQUICConnectTimeout(timeout)

        let slot = QUICCertificateCaptureSlot()
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(
                trustPolicy: .system, connectTimeout: connectTimeout
            ),
            connectTimeout: connectTimeout,
            // The transport resolves `.system` and passes it here; the probe deliberately
            // discards it and installs the internal capture mode instead (design D2). The
            // configuration carries the same normalized deadline the transport arms, so it holds
            // no value that never takes effect, and the capture mode stays unreachable from any
            // public `TrustPolicy`.
            driverFactory: { host, port, _ in driverFactory(host, port, slot) },
            deadline: deadline
        )

        let result: Result<Void, any Error>
        do {
            try await transport.connect(host: endpoint.host, port: endpoint.port)
            result = .success(())
        } catch {
            result = .failure(error)
        }

        // ALWAYS, on every path — `close()` is cancellation-safe (it awaits only non-throwing
        // teardown continuations), so it cannot hang or throw even from an already-cancelled
        // task. It guarantees a started connection was cancelled exactly once and its handlers
        // cleared, which is why the slot is read only after it returns.
        await transport.close()
        let chain = slot.chain

        if case .failure(let error) = result, error is CancellationError {
            // A cancelled task must never observe a success value, captured chain or not.
            throw error
        }
        if let chain {
            return chain
        }
        if case .failure(let error) = result {
            throw error
        }
        throw POSIXError(
            .EPROTO,
            description: "QUIC certificate probe: handshake completed but no certificate was captured"
        )
    }
    #endif // canImport(Network)
}
