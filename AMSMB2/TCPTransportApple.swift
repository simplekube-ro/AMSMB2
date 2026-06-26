//
//  TCPTransportApple.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  NIOTransportServices-backed `SMBTransport` for Apple platforms.
//
//  **Apple-only** (`#if canImport(Network)`). On Linux the legacy libsmb2-owned
//  TCP path remains unchanged (design D7).
//
//  **Design D2**: `SMBTransport` uses `Data` at the seam; `ByteBuffer` conversions
//  live *inside* this file so the protocol stays NIO-free.
//
//  **Design D3**: `@unchecked Sendable` is justified because all mutable state
//  (`_channel`, `_isClosed`) is guarded by `NSLock`. The `InboundBufferingHandler`
//  also guards its own mutable state with a separate `NSLock`; it runs on the NIO
//  event loop for NIO callbacks and under the lock for async `receive()` callers.
//
//  **Error mapping**: All NWError / ChannelError values are converted to `POSIXError`
//  before propagating to callers, matching the CLAUDE.md convention.
//

#if canImport(Network)

import Foundation
import Network
import NIOCore
import NIOTransportServices

// MARK: - TCPTransportApple

/// An `SMBTransport` backed by NIOTransportServices (Network.framework) on Apple platforms.
///
/// One instance maps to one TCP connection lifetime. After `close()` the instance is
/// unusable; create a fresh one to reconnect.
///
/// Thread-safety: all mutable state is guarded by `NSLock`. Conforms to `Sendable`
/// via `@unchecked Sendable` (design D3).
public final class TCPTransportApple: SMBTransport, @unchecked Sendable {

    // MARK: - State

    private let group: NIOTSEventLoopGroup
    private let connectTimeoutSeconds: Int
    /// Channel set after a successful `connect`. Guarded by `lock`.
    private var _channel: (any Channel)?
    /// Set by `close()` to prevent re-use after teardown. Guarded by `lock`.
    private var _isClosed = false
    private let lock = NSLock()
    /// Accumulates inbound bytes from the NIO channel for async `receive()` calls.
    private let inboundHandler = InboundBufferingHandler()

    // MARK: - Init / deinit

    /// Creates a new transport.
    ///
    /// - Parameter connectTimeoutSeconds: Maximum time (in whole seconds) allowed for the
    ///   TCP handshake. Defaults to 30 seconds, matching the libsmb2 default.
    public init(connectTimeoutSeconds: Int = 30) {
        self.group = NIOTSEventLoopGroup(loopCount: 1)
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    deinit {
        // Safety-net: if the caller did not call close(), attempt to close the channel
        // and synchronously drain the NIO event loop.
        // CAVEAT: syncShutdownGracefully() will deadlock/precondition-fail if deinit
        // ever runs on one of the group's own event-loop threads. The likelihood is low
        // because the group's event loops do not retain the transport object, but
        // callers are strongly encouraged to call close() for deterministic teardown.
        lock.withLock { _channel }?.close(promise: nil)
        try? group.syncShutdownGracefully()
    }

    // MARK: - SMBTransport

    /// Establishes a TCP connection to `host:port` via Network.framework.
    ///
    /// Supports task cancellation: if the enclosing `Task` is cancelled while the
    /// NIO bootstrap is still connecting, the underlying NWConnection is closed as
    /// soon as it becomes available and `POSIXError(.ECANCELED)` is thrown.
    public func connect(host: String, port: Int) async throws {
        // Guard: re-use after close() is not supported.
        let isClosed = lock.withLock { _isClosed }
        guard !isClosed else {
            throw POSIXError(.ENOTCONN, description: "TCPTransportApple: transport is closed")
        }

        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.seconds(Int64(connectTimeoutSeconds)))
            .channelInitializer { [inboundHandler] channel in
                channel.pipeline.addHandler(inboundHandler)
            }

        // Kick off the connect. The future resolves on the NIO event loop.
        let connectFuture = bootstrap.connect(host: host, port: port)

        do {
            let channel = try await withTaskCancellationHandler(
                operation: {
                    // EventLoopFuture.get() is not cooperatively cancellable — the future runs
                    // to completion regardless. The onCancel closure below closes the NWConnection
                    // as soon as it becomes available, which causes the future to complete quickly
                    // with a channel-closed error.
                    try await connectFuture.get()
                },
                onCancel: {
                    // Fires on an unspecified thread when the enclosing Task is cancelled.
                    // Schedule the channel close on the event loop so NWConnection.cancel() is
                    // called, unblocking the future.
                    connectFuture.whenSuccess { channel in
                        channel.close(promise: nil)
                    }
                }
            )

            // Re-check after get() returns: if we were cancelled while the future was completing
            // we might have a valid channel that we must not keep.
            if Task.isCancelled {
                channel.close(promise: nil)
                throw POSIXError(.ECANCELED)
            }

            lock.withLock { _channel = channel }
        } catch is CancellationError {
            throw POSIXError(.ECANCELED)
        } catch let posix as POSIXError {
            throw posix
        } catch {
            // If the task was cancelled, the onCancel handler may have closed the channel
            // before the future completed, causing a ChannelError rather than CancellationError.
            // Honour cancellation semantics by checking the flag here.
            if Task.isCancelled {
                throw POSIXError(.ECANCELED)
            }
            throw Self.mapError(error)
        }
    }

    /// Writes `bytes` to the channel.
    public func send(_ bytes: Data) async throws {
        guard let channel = lock.withLock({ _channel }) else {
            throw POSIXError(.ENOTCONN, description: "TCPTransportApple: not connected")
        }
        // Data → ByteBuffer conversion (design D2).
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Returns the next chunk of bytes from the remote peer.
    ///
    /// Delegates to `InboundBufferingHandler.receive()`. Returns empty `Data` on
    /// graceful EOF (including after `close()`). Supports task cancellation.
    ///
    /// All NWError / ChannelError values thrown by the inbound handler are mapped
    /// to `POSIXError` before propagating (CLAUDE.md convention).
    public func receive() async throws -> Data {
        // EOF convention (SMBTransport contract): return empty Data after close()
        // rather than throwing, consistent with graceful peer-close signalling.
        if lock.withLock({ _isClosed }) {
            return Data()
        }
        guard lock.withLock({ _channel }) != nil else {
            throw POSIXError(.ENOTCONN, description: "TCPTransportApple: not connected")
        }
        // Map any raw NIO / NW errors from the handler to POSIXError before
        // they reach the caller, satisfying the file-level invariant.
        do {
            return try await inboundHandler.receive()
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Closes the connection and shuts down the NIO event loop group.
    ///
    /// Idempotent — safe to call multiple times.
    public func close() async {
        let channel: (any Channel)? = lock.withLock {
            guard !_isClosed else { return nil }
            _isClosed = true
            let ch = _channel
            _channel = nil
            return ch
        }

        if let channel {
            try? await channel.close().get()
        }

        // Close the inbound handler's waiting receiver so any suspended receive() unblocks.
        inboundHandler.signalClosed()

        try? await group.shutdownGracefully()
    }

    // MARK: - Error mapping

    /// Maps NIO / Network.framework errors to `POSIXError`, matching the CLAUDE.md convention.
    private static func mapError(_ error: any Error) -> any Error {
        if error is CancellationError {
            return POSIXError(.ECANCELED)
        }
        if let nwError = error as? NWError {
            return nwError.asPOSIXError()
        }
        if let channelError = error as? ChannelError {
            return channelError.asPOSIXError()
        }
        return error
    }
}

// MARK: - NWError → POSIXError

private extension NWError {
    func asPOSIXError() -> POSIXError {
        switch self {
        case .posix(let code):
            return POSIXError(code)
        case .dns:
            return POSIXError(.EHOSTUNREACH, description: "DNS resolution failed: \(self)")
        case .tls:
            return POSIXError(.EPROTO, description: "TLS error: \(self)")
        case .wifiAware:
            // NWError.wifiAware was added in macOS 12 / iOS 15. Modern Xcode (14+) only ships
            // SDKs that define this case, so omitting it causes a non-exhaustive-switch warning.
            // Keeping it explicit here is safe: older Xcode versions (which lacked the case)
            // are no longer in the CI matrix.
            return POSIXError(.ENETUNREACH, description: "Wi-Fi Aware error: \(self)")
        @unknown default:
            return POSIXError(.EIO, description: "Network error: \(self)")
        }
    }
}

// MARK: - ChannelError → POSIXError

private extension ChannelError {
    func asPOSIXError() -> POSIXError {
        switch self {
        case .ioOnClosedChannel, .alreadyClosed, .inputClosed:
            return POSIXError(.ENOTCONN)
        case .outputClosed:
            return POSIXError(.EPIPE)
        case .connectPending:
            return POSIXError(.EALREADY)
        case .connectTimeout:
            return POSIXError(.ETIMEDOUT)
        case .operationUnsupported:
            return POSIXError(.ENOTSUP)
        case .inappropriateOperationForState:
            return POSIXError(.EINVAL)
        default:
            return POSIXError(.EIO)
        }
    }
}

// MARK: - InboundBufferingHandler

/// NIO `ChannelInboundHandler` that accumulates inbound bytes and delivers them to
/// async `receive()` callers via a lock-guarded continuation.
///
/// **Concurrency model** (design D3):
/// - NIO event-loop callbacks (`channelRead`, `channelInactive`, `errorCaught`) run on the
///   channel's event loop — never from async Swift tasks.
/// - `receive()` is called from async Swift tasks (on any executor).
/// - All shared mutable state is protected by `lock` so neither side needs `await` in
///   the critical section (CLAUDE.md: no `NSLock.lock()` inside an async function body).
final class InboundBufferingHandler: ChannelInboundHandler, @unchecked Sendable {

    typealias InboundIn = ByteBuffer

    // MARK: - State

    private let lock = NSLock()
    /// Bytes received from the channel but not yet consumed by `receive()`.
    private var buffer = Data()
    /// `true` when `channelInactive` fires (graceful or forced close).
    private var isEOF = false
    /// Error caught from `errorCaught`; `receive()` re-throws it.
    private var pendingError: (any Error)?
    /// A continuation suspended in `receive()` waiting for the next chunk.
    private var waitingContinuation: CheckedContinuation<Data, any Error>?

    // MARK: - ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = Self.unwrapInboundIn(data)
        // ByteBuffer → Data conversion (design D2). readableBytesView is a contiguous
        // slice — copying it here is the canonical NIO pattern and satisfies design D4
        // (copy at the boundary before the ByteBuffer may be returned to the pool).
        let received = Data(byteBuffer.readableBytesView)

        // Capture the continuation under the lock, then resume outside it.
        let continuation: CheckedContinuation<Data, any Error>? = lock.withLock {
            if let cont = waitingContinuation {
                // Fast path: deliver directly to the suspended receive() caller.
                waitingContinuation = nil
                return cont
            } else {
                buffer.append(received)
                return nil
            }
        }
        continuation?.resume(returning: received)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let continuation: CheckedContinuation<Data, any Error>? = lock.withLock {
            isEOF = true
            let cont = waitingContinuation
            waitingContinuation = nil
            return cont
        }
        continuation?.resume(returning: Data())
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        let continuation: CheckedContinuation<Data, any Error>? = lock.withLock {
            pendingError = error
            let cont = waitingContinuation
            waitingContinuation = nil
            return cont
        }
        continuation?.resume(throwing: error)
        context.close(promise: nil)
    }

    // MARK: - Async receive

    /// Returns the next available chunk of bytes, suspending if none are buffered.
    ///
    /// Returns empty `Data` on EOF. Supports task cancellation.
    func receive() async throws -> Data {
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    // All state reads and the continuation store happen under the lock so
                    // NIO event-loop callbacks can't race with us.
                    self.lock.withLock {
                        if !self.buffer.isEmpty {
                            // Fast path: data already available.
                            let data = self.buffer
                            self.buffer = Data()
                            continuation.resume(returning: data)
                        } else if self.isEOF {
                            continuation.resume(returning: Data())
                        } else if let error = self.pendingError {
                            continuation.resume(throwing: error)
                        } else if Task.isCancelled {
                            // Check cancellation before storing the continuation to close
                            // the race where onCancel fired before we got here.
                            continuation.resume(throwing: CancellationError())
                        } else {
                            self.waitingContinuation = continuation
                        }
                    }
                }
            },
            onCancel: { [self] in
                // Fires on an arbitrary thread; the lock is re-entrant-safe here because
                // onCancel only runs when the continuation is stored — not inside withLock.
                let continuation: CheckedContinuation<Data, any Error>? = lock.withLock {
                    let cont = waitingContinuation
                    waitingContinuation = nil
                    return cont
                }
                continuation?.resume(throwing: CancellationError())
            }
        )
    }

    /// Called by `TCPTransportApple.close()` to unblock any suspended `receive()` call.
    func signalClosed() {
        let continuation: CheckedContinuation<Data, any Error>? = lock.withLock {
            isEOF = true
            let cont = waitingContinuation
            waitingContinuation = nil
            return cont
        }
        continuation?.resume(returning: Data())
    }
}

#endif // canImport(Network)
