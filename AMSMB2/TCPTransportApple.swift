//
//  TCPTransportApple.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  NIOTransportServices-backed `SMBTransport` for Apple platforms.
//
//  **Status:** placeholder stub — full implementation is provided in T7 (#26).
//  This file provides the type declaration so `SMB2Client.connect(transportKind:)` can
//  dispatch to it in T6 without having the NIO channel code present yet.
//

#if canImport(Network)

import Foundation
import NIOCore
import NIOTransportServices

// MARK: - TCPTransportApple

/// An `SMBTransport` backed by NIOTransportServices (Network.framework) on Apple platforms.
///
/// **Apple-only** (`#if canImport(Network)`). The Linux build uses libsmb2's built-in TCP
/// socket via the legacy DispatchSource loop; this type is never compiled there (design D7).
///
/// **T7 (#26) provides the full implementation.** Until then, every method throws
/// `POSIXError(.ENOTSUP)` so that callers get a clear compile-time visible placeholder rather
/// than a runtime crash.
public final class TCPTransportApple: SMBTransport {

    public init() {}

    public func connect(host: String, port: Int) async throws {
        throw POSIXError(.ENOTSUP, description:
            "TCPTransportApple: full implementation ships in T7 (#26)")
    }

    public func send(_ bytes: Data) async throws {
        throw POSIXError(.ENOTSUP, description:
            "TCPTransportApple: full implementation ships in T7 (#26)")
    }

    public func receive() async throws -> Data {
        throw POSIXError(.ENOTSUP, description:
            "TCPTransportApple: full implementation ships in T7 (#26)")
    }

    public func close() async {}
}

#endif // canImport(Network)
