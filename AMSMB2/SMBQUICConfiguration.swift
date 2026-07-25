//
//  SMBQUICConfiguration.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation

// MARK: - SMBQUICConfiguration

/// Configuration for an SMB-over-QUIC connection (design D5/D10).
///
/// **Platform-neutral by construction.** This type holds no Security.framework
/// (`SecCertificate`) or Network.framework values — trust anchors are DER-encoded
/// `[Data]` and the connect deadline is a `TimeInterval`. It therefore compiles and is
/// public API on every platform, including Linux, where `.quic` is inert (it throws
/// `POSIXError(.ENOTSUP)` before any transport is constructed). The DER → `SecCertificate`
/// conversion happens only inside the Apple-only QUIC transport.
///
/// The value is snapshotted under the manager's `connectLock` before a connect begins, so
/// mutating it never races an in-flight attempt and never mutates an established connection —
/// new values apply to the next connect (design D6).
public struct SMBQUICConfiguration: Sendable, Equatable {
    // MARK: - TrustPolicy

    /// How the TLS server certificate is validated during the QUIC handshake.
    ///
    /// A single enum makes "custom roots **and** insecure" unrepresentable — there is no
    /// conflicting-configuration state to reject at runtime (design D5).
    public enum TrustPolicy: Sendable, Equatable {
        /// Default: the system trust store evaluates the chain and the hostname is verified.
        case system

        /// DER-encoded certificates that **replace** the system anchors. The set must be
        /// non-empty; the hostname is still verified. Intended for private-CA / self-signed
        /// lab setups. Not certificate pinning — this is anchor replacement.
        case customRoots([Data])

        /// Debug-only escape hatch: certificate-chain validation and hostname verification are
        /// both disabled. TLS 1.3 encryption, the ALPN `"smb"` requirement, and the QUIC
        /// handshake itself remain active. Never bypasses numeric-host rejection (design D4).
        case insecureNoVerification
    }

    // MARK: - Stored properties

    /// The TLS trust policy applied during the QUIC handshake. Defaults to `.system`.
    public var trustPolicy: TrustPolicy = .system

    /// The QUIC connect deadline in seconds. Defaults to 30. Dedicated, finite, and always
    /// armed — independent of `SMB2Manager.timeout` (design D10). Validated and normalized at
    /// connect: non-finite / non-positive values are rejected; values above 3600 are clamped.
    public var connectTimeout: TimeInterval = 30

    // MARK: - Init

    /// Creates a configuration. All parameters default to the secure, conventional values.
    public init(trustPolicy: TrustPolicy = .system, connectTimeout: TimeInterval = 30) {
        self.trustPolicy = trustPolicy
        self.connectTimeout = connectTimeout
    }
}
