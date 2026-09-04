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
//  (`_channel`, `_closeState`, `_connectAttempt`, …) is guarded by `NSLock`. The `InboundBufferingHandler`
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
    /// Close lifecycle (design D6): the first `close()` caller atomically becomes the
    /// teardown **owner** (`.open → .closing`); callers arriving during `.closing` park in
    /// `closeWaiters` and are resumed exactly once, only after the owner has fully finished
    /// (channel closed, receiver unblocked, connect tail drained, group shut down) and
    /// published `.closed`. Only a call made after `.closed` returns immediately as the
    /// terminal no-op. Guarded by `lock`.
    private enum CloseState {
        case open
        case closing
        case closed
    }

    private var _closeState: CloseState = .open
    /// `close()` callers parked while another caller owns the teardown. Guarded by `lock`.
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    /// `true` from the one-shot reservation until the owning `connect` call's tail has fully
    /// finished (design D7). While set, the close owner parks in `connectWorkWaiters` before
    /// the group shutdown and the `.closed` publication, so a returned `close()` proves the
    /// connect tail can no longer create or retain resources. Guarded by `lock`.
    private var connectWorkInFlight = false
    /// Close owner parked until the in-flight connect work completes. Guarded by `lock`.
    private var connectWorkWaiters: [CheckedContinuation<Void, Never>] = []
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

    // MARK: - Test seams (design D8; internal, inert in production)

    /// Awaited (when set) immediately before the success-publication critical section, so a
    /// deterministic test can hold a successful bootstrap at exactly the racy point. Guarded
    /// by `lock`; always `nil` in production.
    private var _connectPublicationGate: (@Sendable () async -> Void)?
    /// Awaited (when set) by the close teardown before the event-loop-group shutdown, so a
    /// deterministic test can hold the teardown mid-way. Guarded by `lock`; always `nil` in
    /// production.
    private var _closeTeardownGate: (@Sendable () async -> Void)?
    /// How many times a never-published connect channel was closed (test observability for
    /// the exactly-once teardown assertion). Guarded by `lock`.
    private var _abortedConnectChannelCloseCount = 0

    var connectPublicationGate: (@Sendable () async -> Void)? {
        get { lock.withLock { _connectPublicationGate } }
        set { lock.withLock { _connectPublicationGate = newValue } }
    }

    var closeTeardownGate: (@Sendable () async -> Void)? {
        get { lock.withLock { _closeTeardownGate } }
        set { lock.withLock { _closeTeardownGate = newValue } }
    }

    var abortedConnectChannelCloseCount: Int {
        lock.withLock { _abortedConnectChannelCloseCount }
    }

    /// Whether a successfully-published channel is currently installed.
    var hasInstalledChannel: Bool {
        lock.withLock { _channel != nil }
    }

    /// How many `close()` callers are currently parked — the owner awaiting the connect
    /// tail plus concurrent callers awaiting the owner (mirrors `QUICTransportApple`).
    var pendingCloseWaiterCount: Int {
        lock.withLock { closeWaiters.count + connectWorkWaiters.count }
    }

    /// Takes ownership of the connecting channel — the caller MUST close the returned
    /// channel exactly once — and counts the aborted-connect closure (design D7 ownership
    /// transfer: whoever takes `_connectingChannel` out of the state closes it; `nil` means
    /// another path already took it, or none exists). MUST be called while holding `lock`.
    private func takeConnectingChannelLocked() -> (any Channel)? {
        guard let channel = _connectingChannel else { return nil }
        _connectingChannel = nil
        _abortedConnectChannelCloseCount += 1
        return channel
    }

    /// Marks the connect attempt's tail finished and resumes a close owner parked on it
    /// (design D7). Runs via `defer` on every exit path of the owning `connect` call.
    private func finishConnectWork() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            connectWorkInFlight = false
            let waiters = connectWorkWaiters
            connectWorkWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: ())
        }
    }

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
        // onCancel — which requires the reservation — and `close()`, which leaves
        // `.open` forever), so no per-attempt reset is needed.
        try lock.withLock {
            guard _closeState == .open else {
                throw POSIXError(.ENOTCONN, description: "TCPTransportApple: transport is closed")
            }
            switch _connectAttempt {
            case .idle:
                _connectAttempt = .inFlight
                connectWorkInFlight = true
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

        // The reserved attempt's entire tail counts as in-flight connect work (design D7);
        // finish it on every exit path. Declared first so it runs LAST of the defers —
        // after all other state cleanup — which is what lets a parked close owner treat
        // its resumption as "the tail can no longer create or retain resources".
        defer { finishConnectWork() }

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
                        guard !self._connectCancelled else {
                            self._abortedConnectChannelCloseCount += 1
                            return true
                        }
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
                        return self.takeConnectingChannelLocked()
                    }
                    channelToClose?.close(promise: nil)
                }
            )

            // Test seam (D8): hold a successful bootstrap at exactly the pre-publication point.
            if let gate = connectPublicationGate {
                await gate()
            }

            // Publication claim (design D5): one critical section decides success-versus-
            // terminal-events — precedence close, then cancellation — and consumes the
            // one-shot attempt either way. No terminal close/cancellation state can be
            // overwritten by `.connected`, no publication is possible once close() claimed
            // `.closing`, and a channel that lost the claim is closed exactly once (a `nil`
            // take means close()/onCancel already took and closed it). Close is checked
            // before the cancel latch because close() also sets the latch to abort the
            // channelInitializer — latch-first would misreport a plain close as ECANCELED.
            enum PublicationOutcome {
                case published
                case closeWon
                case cancellationWon
            }
            let (outcome, orphan): (PublicationOutcome, (any Channel)?) = lock.withLock {
                guard _closeState == .open else {
                    _connectAttempt = .failed
                    return (.closeWon, takeConnectingChannelLocked())
                }
                // `_connectCancelled` covers an onCancel that fired while the handler was in
                // scope; `Task.isCancelled` covers a cancellation after the handler exited
                // (the old post-`get()` re-check, now folded inside the claim).
                guard !_connectCancelled, !Task.isCancelled else {
                    _connectAttempt = .failed
                    return (.cancellationWon, takeConnectingChannelLocked())
                }
                _channel = channel
                _connectingChannel = nil // ownership transferred to `_channel`.
                _connectAttempt = .connected
                return (.published, nil)
            }
            orphan?.close(promise: nil)
            switch outcome {
            case .published:
                break
            case .closeWon:
                throw POSIXError(.ENOTCONN, description: "TCPTransportApple: closed during connect")
            case .cancellationWon:
                throw POSIXError(.ECANCELED)
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
        // rather than throwing, consistent with graceful peer-close signalling. A transport
        // in `.closing` is already closed from the caller's perspective.
        if lock.withLock({ _closeState != .open }) {
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

    /// Closes the connection and shuts down the NIO event loop group through the owned
    /// close lifecycle `open → closing(waiters) → closed` (design D6/D7).
    ///
    /// The first caller atomically becomes the teardown **owner**: it aborts any in-flight
    /// connect (cancel latch + taking/closing whichever channel exists, which also prevents
    /// any later publication — the D5 claim cannot publish once `.closing` is set), unblocks
    /// a suspended `receive()`, drains the connect tail, shuts the event-loop group down
    /// strictly last, then publishes `.closed` and resumes every parked caller exactly once.
    /// A `close()` arriving during `.closing` returns only after that same completed
    /// teardown; only a call after `.closed` returns immediately as the terminal no-op.
    /// Teardown failures are swallowed (`close()` is non-throwing) but never let a waiter
    /// return before the teardown completed. No lock is held across an `await`, a NIO call,
    /// or a continuation resumption.
    public func close() async {
        enum Entry {
            case alreadyClosed
            case waitForOwner
            case own((any Channel)?)
        }
        let entry: Entry = lock.withLock {
            switch _closeState {
            case .closed:
                return .alreadyClosed
            case .closing:
                return .waitForOwner
            case .open:
                _closeState = .closing
                // Abort an in-flight connect too: flag the cancellation (so a not-yet-run
                // channelInitializer closes its channel on arrival) and take whichever
                // channel exists — the connected one, or the one still being established
                // (the take is the exactly-once ownership transfer; the publication claim
                // then finds nothing left to close and cannot publish into `.closing`).
                _connectCancelled = true
                if let established = _channel {
                    _channel = nil
                    return .own(established)
                }
                return .own(takeConnectingChannelLocked())
            }
        }

        switch entry {
        case .alreadyClosed:
            return // terminal no-op: a prior close fully completed its teardown.

        case .waitForOwner:
            // Park until the owner's teardown has fully completed and `.closed` published
            // (re-checked under the lock so a caller can never park after that happened).
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked: Bool = lock.withLock {
                    guard _closeState == .closing else { return false } // owner finished meanwhile.
                    closeWaiters.append(continuation)
                    return true
                }
                if !parked {
                    continuation.resume(returning: ())
                }
            }

        case .own(let channel):
            if let channel {
                try? await channel.close().get()
            }

            // Close the inbound handler's waiting receiver so any suspended receive() unblocks.
            inboundHandler.signalClosed()

            // Test seam (D8): hold the owner's teardown before the connect-tail drain and
            // the event-loop-group shutdown.
            if let gate = closeTeardownGate {
                await gate()
            }

            // Drain the connect tail (design D7). The aborted attempt resolves promptly —
            // its channel was just closed, or the cancel latch closes it on arrival — and
            // once drained, no connect work can create or retain resources.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked: Bool = lock.withLock {
                    guard connectWorkInFlight else { return false }
                    connectWorkWaiters.append(continuation)
                    return true
                }
                if !parked {
                    continuation.resume(returning: ())
                }
            }

            // Group shutdown strictly last — no NIO work is outstanding by now.
            try? await group.shutdownGracefully()

            // Fully closed: publish and release every parked caller exactly once.
            let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                _closeState = .closed
                let parked = closeWaiters
                closeWaiters = []
                return parked
            }
            for waiter in waiters {
                waiter.resume(returning: ())
            }
        }
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
        InboundSignposts.transportRead(bytes: received.count)

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
