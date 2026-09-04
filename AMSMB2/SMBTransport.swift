//
//  SMBTransport.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation

// MARK: - InboundReceiver

/// The seam's inbound receiver: the handler a caller supplies to
/// ``SMBTransport/connect(host:port:onReceive:)``.
///
/// A transport invokes it on its own serial delivery queue — once per inbound chunk in arrival
/// order, once with empty `Data` for graceful EOF, or once with a `POSIXError` for abnormal
/// connection loss. EOF and failure are terminal, and nothing is delivered once `close()` has
/// begun. It must return promptly and must not suspend: it runs on the network queue.
public typealias InboundReceiver = @Sendable (Result<Data, POSIXError>) -> Void

// MARK: - SMBTransport

/// The async transport seam shared by all concrete transports (TCP, QUIC).
///
/// A conforming type is responsible for carrying raw SMB2 bytes over the
/// network. The protocol is intentionally free of SwiftNIO and libsmb2
/// dependencies so that conformers can be unit-tested in isolation and
/// reused by both the TCP and QUIC transports.
///
/// **Buffer type:** `send(_:)` and the `onReceive` handler's payload use
/// `Foundation.Data` (design decision D2). Concrete transports convert
/// to/from NIO `ByteBuffer` internally, keeping this seam dependency-free.
///
/// **Inbound is push:** a connection cannot exist without its receiver —
/// `connect(host:port:onReceive:)` takes the handler, so there is no pull
/// operation, no registration step that could be skipped, and no
/// "bytes arrived but nobody is listening" state in any conformer.
///
/// **EOF convention:** the handler is invoked with empty `Data` to signal a
/// graceful peer close, and with a `POSIXError` failure for abnormal loss.
///
/// **Swift 6 concurrency:** conforming types must be `Sendable`. Use
/// `actor` for mutable-state conformers; `final class` requires explicit
/// `Sendable` justification.
public protocol SMBTransport: Sendable {

    /// Establishes a connection to `host` on `port` and installs `onReceive` as the
    /// connection's inbound receiver.
    ///
    /// Throws `POSIXError` on failure (e.g. `.ECONNREFUSED`).
    ///
    /// **Delivery contract.** The transport invokes `onReceive` on its own serial delivery
    /// queue: once per inbound chunk in arrival order, once with empty `Data` for graceful
    /// EOF, or once with a `POSIXError` for abnormal connection loss. EOF and failure are
    /// terminal — nothing is delivered after either — and nothing is delivered once `close()`
    /// has begun. The handler is expected to return promptly and MUST NOT suspend: it runs on
    /// the network queue, so a slow handler delays the next read.
    ///
    /// A `connect` that throws never invokes its handler, and a `connect` that is rejected
    /// because the instance already has an attempt or a connection never replaces the live
    /// receiver.
    ///
    /// An instance represents a single connection lifetime: callers create a
    /// fresh transport per connection (as `SMB2Client` does) rather than
    /// reusing one across connects. Both in-tree conformers are strictly
    /// one-shot and reject every call after the first deterministically:
    /// `EALREADY` while an attempt is in flight or after a failed attempt,
    /// `EISCONN` once connected, and — deliberately keeping each conformer's
    /// pre-existing closed contract — `ECONNABORTED` after `close()` on
    /// `QUICTransportApple` versus `ENOTCONN` on `TCPTransportApple`.
    func connect(host: String, port: Int, onReceive: @escaping InboundReceiver) async throws

    /// Sends `bytes` to the remote peer.
    func send(_ bytes: Data) async throws

    /// Closes the connection and releases all resources, including the inbound receiver.
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
