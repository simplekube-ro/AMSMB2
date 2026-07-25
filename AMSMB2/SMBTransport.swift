//
//  SMBTransport.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation

// MARK: - SMBTransport

/// The async transport seam shared by all concrete transports (TCP, QUIC).
///
/// A conforming type is responsible for carrying raw SMB2 bytes over the
/// network. The protocol is intentionally free of SwiftNIO and libsmb2
/// dependencies so that conformers can be unit-tested in isolation and
/// reused by both the TCP and QUIC transports.
///
/// **Buffer type:** `send(_:)` and `receive()` use `Foundation.Data`
/// (design decision D2). Concrete transports convert to/from NIO
/// `ByteBuffer` internally, keeping this seam dependency-free.
///
/// **EOF convention:** `receive()` returns empty `Data` to signal a
/// graceful peer close. Callers should stop the receive loop on empty
/// result.
///
/// **Swift 6 concurrency:** conforming types must be `Sendable`. Use
/// `actor` for mutable-state conformers; `final class` requires explicit
/// `Sendable` justification.
public protocol SMBTransport: Sendable {

    /// Establishes a connection to `host` on `port`.
    ///
    /// Throws `POSIXError` on failure (e.g. `.ECONNREFUSED`).
    ///
    /// An instance represents a single connection lifetime: callers create a
    /// fresh transport per connection (as `SMB2Client` does) rather than
    /// reusing one across connects. Both in-tree conformers are strictly
    /// one-shot and reject every call after the first deterministically:
    /// `EALREADY` while an attempt is in flight or after a failed attempt,
    /// `EISCONN` once connected, and — deliberately keeping each conformer's
    /// pre-existing closed contract — `ECONNABORTED` after `close()` on
    /// `QUICTransportApple` versus `ENOTCONN` on `TCPTransportApple`.
    func connect(host: String, port: Int) async throws

    /// Sends `bytes` to the remote peer.
    func send(_ bytes: Data) async throws

    /// Returns the next chunk of bytes from the remote peer.
    ///
    /// An empty `Data` return value signals graceful EOF (peer close).
    /// Propagates thrown errors for abnormal connection loss.
    func receive() async throws -> Data

    /// Closes the connection and releases all resources.
    ///
    /// When `close()` returns, the connection's resources are released — for
    /// every caller: repeated and concurrent calls are safe, and a call made
    /// while another close is still tearing down returns only after that
    /// teardown has completed. Only a call made after a prior close fully
    /// completed may return immediately as a no-op.
    func close() async
}

// MARK: - SMBTransportKind

/// Selects which transport implementation a connection uses.
///
/// - `tcp`: Explicit TCP transport. On Apple platforms this routes through
///   `NIOTransportServices` (Network.framework); on Linux it falls back to
///   libsmb2's built-in BSD socket.
/// - `quic`: SMB-over-QUIC transport (`QUICTransportApple`, backed by
///   Network.framework). Explicit opt-in: non-numeric hostnames only,
///   UDP/443 default, no silent TCP fallback. Requires iOS 15 / macOS 12 /
///   macCatalyst 15 / tvOS 15 / watchOS 8 / visionOS 1; below that floor,
///   and on Linux, selecting it throws `POSIXError(.ENOTSUP)`.
/// - `automatic`: Let the library choose the best transport available on
///   the current platform.
public enum SMBTransportKind: Sendable, Equatable, Hashable {
    case tcp
    case quic
    case automatic
}
