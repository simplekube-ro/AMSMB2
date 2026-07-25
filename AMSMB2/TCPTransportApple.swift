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
/// One instance maps to one TCP connection lifetime, and `connect(host:port:)` is strictly
/// **one-shot**: the first call atomically reserves the instance's single connect attempt,
/// and every other call is rejected deterministically without creating a bootstrap or any
/// network activity — `POSIXError(.EALREADY)` while the attempt is in flight or after it
/// failed (retry after a failed attempt is NOT supported; build a fresh transport, as
/// `SMB2Client` does), `POSIXError(.EISCONN)` once connected, and the existing
/// `POSIXError(.ENOTCONN)` after `close()` (checked first). After `close()` the instance is
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
    /// Channel captured in the bootstrap's `channelInitializer` while a connect is in flight —
    /// available *before* the connect completes so a cancellation can abort a still-pending
    /// connect. Cleared once `connect` returns. Guarded by `lock`.
    private var _connectingChannel: (any Channel)?
    /// Set when the in-flight connect is cancelled. If `onCancel` fires before the
    /// `channelInitializer` has run, the initializer observes this and closes the channel
    /// immediately. Never reset — it latches for the lifetime of the instance's single
    /// one-shot attempt. Guarded by `lock`.
    private var _connectCancelled = false
    /// Set by `close()` to prevent re-use after teardown. Guarded by `lock`.
    private var _isClosed = false
    /// One-shot connect attempt state (mirrors `QUICTransportApple`'s reservation): `connect`
    /// may only transition `.idle → .inFlight`, so exactly one call ever owns the attempt;
    /// every other call is rejected by the state it observes (`.inFlight`/`.failed` →
    /// `EALREADY`, `.connected` → `EISCONN`) without creating a bootstrap or touching the
    /// owning attempt's channel. Guarded by `lock`.
    private enum ConnectAttempt {
        case idle
        case inFlight
        case connected
        case failed
    }

    private var _connectAttempt: ConnectAttempt = .idle
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
        // One-shot attempt reservation (atomic; before any bootstrap work). The closed guard
        // keeps its existing contract and precedence. In `.idle` on an open transport,
        // `_connectCancelled` cannot be set (its only writers are an in-flight attempt's
        // onCancel — which requires the reservation — and `close()`, which latches
        // `_isClosed`), so no per-attempt reset is needed.
        try lock.withLock {
            guard !_isClosed else {
                throw POSIXError(.ENOTCONN, description: "TCPTransportApple: transport is closed")
            }
            switch _connectAttempt {
            case .idle:
                _connectAttempt = .inFlight
            case .inFlight:
                throw POSIXError(.EALREADY, description: "TCPTransportApple: connect already in progress")
            case .connected:
                throw POSIXError(.EISCONN, description: "TCPTransportApple: already connected")
            case .failed:
                throw POSIXError(
                    .EALREADY,
                    description: "TCPTransportApple: one-shot connect attempt already consumed"
                )
            }
        }

        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.seconds(Int64(connectTimeoutSeconds)))
            // Raise the NIOTransportServices receive granularity from its 8 KB default so a large
            // SMB2 READ reply (up to the ~1 MB negotiated max-read) arrives in fewer, larger
            // ByteBuffers instead of fragmenting into ~8 KB chunks. Each NWConnection completion
            // drives a Data copy, an inbound-FIFO enqueue, and an eventLoopQueue service hop, so a
            // coarser receive cuts per-byte op-count on the streaming read path. Throughput (per-
            // byte copy volume) is unchanged; this is an op-count optimisation. `minimumIncomplete-
            // ReceiveLength` stays at its default (1) so small control PDUs still flush immediately
            // with no added latency.
            .channelOption(NIOTSChannelOptions.maximumReceiveLength, value: 1 << 18) // 256 KB
            .channelInitializer { [inboundHandler, weak self] channel in
                // Capture the channel the moment it is created — before the connect completes —
                // so a cancellation while the connect is still pending can abort it promptly.
                // (Closing only on `whenSuccess` could never abort a black-holed connect, which
                // would then block until `connectTimeoutSeconds`.) If cancellation already fired
                // before we got here, close immediately.
                if let self {
                    let cancelNow: Bool = self.lock.withLock {
                        guard !self._connectCancelled else { return true }
                        self._connectingChannel = channel
                        return false
                    }
                    if cancelNow { channel.close(promise: nil) }
                }
                return channel.pipeline.addHandler(inboundHandler)
            }

        // Kick off the connect. The future resolves on the NIO event loop.
        let connectFuture = bootstrap.connect(host: host, port: port)
        // `_connectingChannel` is valid only for the duration of this connect; drop it on every
        // exit path (success, failure, or cancellation) so it never outlives the attempt.
        defer { lock.withLock { _connectingChannel = nil } }

        do {
            let channel = try await withTaskCancellationHandler(
                operation: {
                    // EventLoopFuture.get() is not cooperatively cancellable — the future runs
                    // to completion regardless. The onCancel closure below closes the channel
                    // captured in the initializer, which calls NWConnection.cancel() and makes
                    // the future complete quickly with a channel-closed error — even while the
                    // connect is still pending.
                    try await connectFuture.get()
                },
                onCancel: { [weak self] in
                    // Fires on an unspecified thread when the enclosing Task is cancelled. Close
                    // the in-flight channel (if the initializer has run) to abort the connect;
                    // otherwise flag the cancellation so the initializer closes it on arrival.
                    guard let self else { return }
                    let channelToClose: (any Channel)? = self.lock.withLock {
                        self._connectCancelled = true
                        return self._connectingChannel
                    }
                    channelToClose?.close(promise: nil)
                }
            )

            // Re-check after get() returns: if we were cancelled while the future was completing
            // we might have a valid channel that we must not keep.
            if Task.isCancelled {
                channel.close(promise: nil)
                throw POSIXError(.ECANCELED)
            }

            // Publish the channel and consume the one-shot attempt in the same critical
            // section, so no observer sees a connected transport still reporting in-flight.
            lock.withLock {
                _channel = channel
                _connectAttempt = .connected
            }
        } catch {
            // Every failure path consumes the one-shot attempt (retry is unsupported), then
            // applies the pre-existing error mapping unchanged.
            lock.withLock { _connectAttempt = .failed }
            if error is CancellationError {
                throw POSIXError(.ECANCELED)
            }
            if let posix = error as? POSIXError {
                throw posix
            }
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
            // Abort an in-flight connect too: flag the cancellation (so a not-yet-run
            // channelInitializer closes its channel on arrival) and close whichever channel
            // exists — the connected one, or the one still being established.
            _connectCancelled = true
            let ch = _channel ?? _connectingChannel
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
