//
//  TransportBridge.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

#if canImport(Network)

import Foundation
import SMB2

// MARK: - TransportBridge

/// Bridges libsmb2's synchronous external-transport C callbacks to an async `SMBTransport`.
///
/// The bridge resolves the impedance mismatch between libsmb2's synchronous C callbacks and
/// Swift's async transport protocol:
///
/// **Outbound path** (libsmb2 → peer): The C `send` callback copies bytes synchronously into a
/// `Data` value (design D4 — libsmb2 may free the buffer immediately after `send` returns) and
/// enqueues it. The outbound pump `Task` drains the queue by calling `transport.send(_:)` async.
///
/// **Inbound path** (peer → libsmb2): The bridge hands `deliverInbound(_:)` to the transport as
/// the receiver when it connects it (design D2). The transport invokes it on its own delivery
/// queue for every chunk, for graceful EOF and for abnormal loss — no task and no executor hop
/// in between — and it records the delivery in the inbound store and fires the inbound-ready
/// signal. The C `recv` callback drains synchronously from that store, returning the would-block
/// signal when it is empty and the transport is open.
///
/// **Concurrency model** (design D3): All mutable state — including `outboundPumpTask` — is
/// guarded by `NSLock`. Lock sections never contain `await`; async work happens outside the
/// locked sections, and the inbound-ready handler is always invoked outside the lock.
///
/// **Lifetime**: `makeExternalTransport()` calls `Unmanaged.passRetained(self)` to hand the
/// bridge to libsmb2 as `ext.userdata`. The single retained reference is consumed exactly once
/// in the C `close` trampoline via `takeRetainedValue()`. Never call `makeExternalTransport()`
/// more than once per bridge instance.
final class TransportBridge: @unchecked Sendable {

    private let transport: any SMBTransport

    // MARK: - Synchronisation primitive

    /// Guards all mutable state below. Lock sections never contain `await` — see CLAUDE.md.
    private let lock = NSLock()

    // MARK: - Inbound state (transport → libsmb2)

    /// Inbound byte chunks received from the transport but not yet consumed by the C recv
    /// callback, held as a FIFO of owned `Data` values (each already copied out of the NIO
    /// `ByteBuffer` at the transport boundary — design D2/D4). Draining a single contiguous
    /// `Data` with `removeSubrange(..<count)` memmoved the entire queued tail on every `cRecv`
    /// — super-linear against a multi-PDU backlog, since libsmb2 reads each PDU as several tiny
    /// preambles. The FIFO + head cursor drains in O(bytes copied) with no tail shifting, and
    /// enqueues received chunks by reference (no second full-payload copy on append).
    private var inboundChunks: [Data] = []
    /// Bytes of `inboundChunks.first` already consumed by previous `cRecv` calls (a 0-based
    /// offset into the head chunk's logical bytes). Always `0` when `inboundChunks` is empty.
    private var inboundHead = 0
    /// Running total of buffered-but-unconsumed inbound bytes. Maintained incrementally so
    /// `cRecv` can test emptiness and clamp `maxLen` in O(1) without summing the FIFO.
    private var inboundCount = 0
    /// Set when the transport delivers empty Data (graceful peer close).
    private var inboundEOF = false
    /// Set when the transport delivers a failure, or an outbound `send` fails.
    private var inboundError: (any Error)?

    // MARK: - Outbound state (libsmb2 → transport)

    /// Byte chunks enqueued by `cSend()` and drained by the outbound pump.
    private var outboundQueue: [Data] = []
    /// Continuation suspended in `takeOutboundChunk()`, resumed by `enqueueOutbound(_:)`.
    private var outboundContinuation: CheckedContinuation<Data?, Never>?

    // MARK: - Lifecycle state

    /// Set by `close()`. Causes `cRecv()` to return ECONNRESET and terminates pump tasks.
    private var isClosed = false

    /// Set to `true` once `connect(host:port:)` has successfully established the transport.
    /// The C `ext.connect` trampoline (`connectStatus()`) reports this as libsmb2's connect
    /// result: a `>= 0` return is only emitted after the channel is live (fix-seam-connect-ordering).
    private var isPreConnected = false

    // MARK: - Inbound-ready signal

    /// Called (from any thread) immediately after bytes, EOF, or an error are recorded in the
    /// inbound store. SMB2Client sets this to `eventLoopQueue.async { serviceContextForSeam() }`.
    /// Every call after registration comes from the transport's own delivery queue (or, for an
    /// outbound send failure, from the outbound pump Task).
    private var _onInboundReady: (@Sendable () -> Void)?

    // MARK: - Pump task

    private var outboundPumpTask: Task<Void, Never>?

    // MARK: - Init

    init(transport: any SMBTransport) {
        self.transport = transport
    }

    // MARK: - Inbound-ready signal API

    /// Registers a callback that fires (on an unspecified thread) after each inbound
    /// delivery — bytes, EOF, or an error. The callback MUST NOT acquire the bridge's
    /// internal lock. Call this once, before `startOutboundPump()`.
    ///
    /// Registration itself fires the callback once, outside the lock, when the store already
    /// holds bytes, EOF or an error. That closes the window between the eager transport connect
    /// (which installs the inbound handler on the transport) and this registration: a delivery
    /// landing in it would otherwise be a lost wakeup, because `serviceContextForSeam` — reached
    /// only from this callback — is the one path that services libsmb2 with `POLLIN`
    /// (`flushOutboundForSeam` services `POLLOUT` only and the seam timer reads nothing), so such
    /// a chunk would wait for a *later* delivery's signal and, if it were the last one, hang the
    /// connect to its timeout.
    ///
    /// Typical usage: `bridge.setInboundReadyHandler { [weak client] in
    ///     client?.eventLoopQueue.async { client?.serviceContextForSeam() } }`
    func setInboundReadyHandler(_ handler: @Sendable @escaping () -> Void) {
        lock.lock()
        _onInboundReady = handler
        // A pre-registration delivery must not be a lost wakeup (design D2).
        let signalNow = !isClosed && (inboundCount > 0 || inboundEOF || inboundError != nil)
        lock.unlock()
        if signalNow { handler() }
    }

    // MARK: - Lifecycle

    /// Starts the outbound pump (libsmb2 → transport direction). The inbound direction has no
    /// pump: the transport pushes into `deliverInbound(_:)` (design D2/D5).
    ///
    /// Must be called after the transport has been connected, and after the inbound-ready
    /// handler has been registered (design D2 — see the call site in `SMB2Client`).
    ///
    /// Guards the task assignment under `lock` to prevent data races on `outboundPumpTask`
    /// and to guard against accidental double-start (which would leak the previous task).
    func startOutboundPump() {
        lock.lock()
        defer { lock.unlock() }
        guard outboundPumpTask == nil else { return }
        outboundPumpTask = Task { [self] in await outboundPump() }
    }

    /// Tears down the bridge: marks closed, cancels the outbound pump task, and fires
    /// `transport.close()` in a background Task. Idempotent — safe to call more than once.
    /// Called from the C close trampoline. Deliveries that arrive afterwards are ignored.
    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let pendingContinuation = outboundContinuation
        outboundContinuation = nil
        // Capture and nil the pump task under the lock so its Task reference is only
        // accessed while the lock is held — satisfying the @unchecked Sendable contract.
        let capturedOutbound = outboundPumpTask
        outboundPumpTask = nil
        // Clear the inbound-ready handler; bridge is closing, no more signalling needed.
        _onInboundReady = nil
        lock.unlock()

        // Resume any waiting outbound pump outside the lock to avoid priority inversion.
        pendingContinuation?.resume(returning: nil)

        capturedOutbound?.cancel()

        // transport.close() is async; fire-and-forget. Captures transport (not self) so the
        // bridge's own retain count does not prolong the Task's lifetime unnecessarily.
        let closingTransport = transport
        Task { await closingTransport.close() }
    }

    /// Produces a `smb2_external_transport` struct whose four C function pointers delegate to
    /// this bridge and whose `userdata` is `Unmanaged.passRetained(self).toOpaque()`.
    ///
    /// **Lifetime contract**: `passRetained(self)` produces a +1 reference that libsmb2 owns
    /// via `ext.userdata`. The C `close` trampoline below calls `takeRetainedValue()` to consume
    /// that +1 exactly once. The underlying `ext_close` implementation in transport-external.c
    /// uses once-semantics by clearing `ext.close` before invoking the callback (it intentionally
    /// leaves `ext.userdata` live), so `takeRetainedValue()` is guaranteed to fire at most once even
    /// when libsmb2's destroy path calls `ext_close` from multiple places (e.g. `smb2_destroy_context`
    /// directly and again from `negotiate_cb → smb2_close_context → ext_close` within the waitqueue
    /// drain): the second call sees a NULL `ext.close` and returns without re-invoking us. After
    /// close, `ext_close` sets `ext_connected = 0` and the C recv/send leaves return `EAGAIN` instead
    /// of calling our trampolines, so the now-released bridge behind `ext.userdata` is never
    /// dereferenced.
    ///
    /// - Important: Call exactly once per bridge instance.
    func makeExternalTransport() -> smb2_external_transport {
        var ext = smb2_external_transport()
        // passRetained: +1 reference owned by libsmb2 via ext.userdata.
        // Balanced by takeRetainedValue() in the close trampoline below.
        ext.userdata = Unmanaged.passRetained(self).toOpaque()

        // Non-capturing closures assigned to C function pointer fields.
        // Each recovers the bridge from `userdata` via Unmanaged (design D5).

        ext.connect = { userdata, _, _ -> Int32 in
            guard let userdata else { return -1 }
            let bridge = Unmanaged<TransportBridge>.fromOpaque(userdata).takeUnretainedValue()
            // The transport is established eagerly by `connect(host:port:)` before libsmb2
            // begins the handshake (fix-seam-connect-ordering). This trampoline only reports
            // the already-known state; it does NOT initiate a second connect. The host/port
            // libsmb2 parsed are ignored — Context.swift connected to the verbatim endpoint.
            return bridge.connectStatus()
        }

        ext.send = { userdata, buf, len -> Int32 in
            guard let userdata else { return -1 }
            let bridge = Unmanaged<TransportBridge>.fromOpaque(userdata).takeUnretainedValue()
            return bridge.cSend(buf: buf, len: len)
        }

        ext.recv = { userdata, buf, maxLen -> Int32 in
            guard let userdata else { return -1 }
            let bridge = Unmanaged<TransportBridge>.fromOpaque(userdata).takeUnretainedValue()
            return bridge.cRecv(buf: buf, maxLen: maxLen)
        }

        ext.close = { userdata -> Int32 in
            guard let userdata else { return 0 }
            // `takeRetainedValue()` consumes the `passRetained` from `makeExternalTransport()`.
            // ext_close (C) clears `ext.close` before calling us (once-semantics), so this closure
            // fires at most once per bridge — no double-takeRetainedValue risk. `ext.userdata` is
            // left live, but post-close recv/send are blocked by the C `ext_connected` guard, so the
            // bridge released here is never dereferenced afterwards.
            let bridge = Unmanaged<TransportBridge>.fromOpaque(userdata).takeRetainedValue()
            bridge.close()
            return 0
        }

        return ext
    }

    // MARK: - Eager connect (fix-seam-connect-ordering)

    /// Establishes the underlying transport, awaiting the async `connect` to completion.
    ///
    /// Called by `connectWithBridge` on the caller's task — *before* the bridge is handed to
    /// libsmb2 — so that by the time `ext.connect` fires NEGOTIATE the channel is already live.
    /// On success `isPreConnected` is set so the C trampoline (`connectStatus()`) reports `0`.
    /// A connect failure is rethrown (never swallowed) and leaves `isPreConnected` `false`.
    ///
    /// - Important: Call exactly once per bridge. The `ext.connect` trampoline performs no second
    ///   connect — it only reports the state recorded here.
    func connect(host: String, port: Int) async throws {
        // `[weak self]`: bridge → transport → closure → bridge would otherwise be a cycle held
        // until the transport released the closure. Weak keeps the bridge's lifetime exactly the
        // `userdata` retain that the C close trampoline balances (design D2).
        try await transport.connect(host: host, port: port) { [weak self] result in
            self?.deliverInbound(result)
        }
        // Synchronous helper wraps the lock — NSLock.lock() is unavailable in async bodies.
        markPreConnected()
    }

    /// Synchronously records that the eager connect succeeded. Wraps the lock so it can be
    /// called from the async `connect(host:port:)` body (CLAUDE.md: no `lock()` in async).
    private func markPreConnected() {
        lock.lock()
        isPreConnected = true
        lock.unlock()
    }

    // MARK: - C callback implementations (internal for testability)

    /// Called from the C connect trampoline. Reports the result of the eager
    /// `connect(host:port:)` performed earlier: `0` when the transport is established,
    /// `-ECONNREFUSED` otherwise. Performs NO connect itself.
    func connectStatus() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return isPreConnected ? 0 : -ECONNREFUSED
    }

    /// The transport's inbound entry point: the receiver handed to `transport.connect` invokes
    /// this on the transport's own serial delivery queue, once per chunk in arrival order, once
    /// with empty `Data` for graceful EOF, or once with a `POSIXError` for abnormal loss.
    ///
    /// Runs synchronously on that queue — there is no task between the transport and the store —
    /// so the bytes are drainable by `cRecv` and the inbound-ready signal has fired before this
    /// returns.
    func deliverInbound(_ result: Result<Data, POSIXError>) {
        applyInbound(result.mapError { $0 as any Error })
    }

    /// Called from the C send trampoline. Copies bytes synchronously (design D4), enqueues.
    ///
    /// libsmb2 may free `buf` immediately after this function returns, so bytes are copied into
    /// an owned `Data` before this function returns — no `await` inside the copy (CLAUDE.md).
    ///
    /// - Returns: `len` on success, negative on invalid arguments.
    func cSend(buf: UnsafePointer<UInt8>?, len: Int) -> Int32 {
        guard let buf, len > 0 else { return 0 }
        // Synchronous copy — no await here; `buf` may be freed after this function returns.
        let data = Data(bytes: buf, count: len)
        enqueueOutbound(data)
        return Int32(len)
    }

    /// Called from the C recv trampoline. Drains the inbound buffer synchronously.
    ///
    /// Return convention (mirrors a non-blocking socket + design D5):
    /// - Positive: bytes copied into `buf`.
    /// - 0: graceful EOF (peer closed the connection).
    /// - Negative + `errno = EAGAIN`: would-block (buffer empty, transport open).
    /// - Negative + `errno = ECONNRESET`: transport error or bridge was closed.
    func cRecv(buf: UnsafeMutablePointer<UInt8>?, maxLen: Int) -> Int32 {
        guard let buf, maxLen > 0 else {
            errno = EINVAL
            return -1
        }

        lock.lock()
        defer { lock.unlock() }

        // Closed state takes priority — prevent libsmb2 from processing stale data.
        if isClosed {
            errno = ECONNRESET
            return -1
        }

        if inboundCount > 0 {
            // Gather up to `maxLen` bytes by walking the front of the FIFO, advancing the head
            // cursor across chunk boundaries. Synchronous copies into the C buffer — no await
            // (design D4, CLAUDE.md constraint). libsmb2 re-calls cRecv for any remainder, so
            // returning fewer than `maxLen` (a short read) is valid.
            let wanted = min(maxLen, inboundCount)
            var copied = 0
            while copied < wanted, let chunk = inboundChunks.first {
                let available = chunk.count - inboundHead
                let take = min(available, wanted - copied)
                // `withUnsafeBytes` exposes the chunk's logical bytes rebased to offset 0, so
                // `inboundHead` indexes correctly even for a non-zero-`startIndex` `Data` slice.
                chunk.withUnsafeBytes { rawSrc in
                    guard let base = rawSrc.baseAddress else { return }
                    let src = base.assumingMemoryBound(to: UInt8.self) + inboundHead
                    (buf + copied).update(from: src, count: take)
                }
                copied += take
                if take == available {
                    // Head chunk fully consumed — drop it and reset the cursor.
                    inboundChunks.removeFirst()
                    inboundHead = 0
                } else {
                    // Head chunk partially consumed — advance the cursor; the loop now exits.
                    inboundHead += take
                }
            }
            inboundCount -= copied
            InboundSignposts.recv(bytes: copied)
            return Int32(copied)
        }

        if inboundEOF {
            InboundSignposts.recv(bytes: 0)
            return 0
        }

        if inboundError != nil {
            errno = ECONNRESET
            return -1
        }

        // Would-block: inbound buffer is empty and the transport is still open.
        InboundSignposts.recvWouldBlock()
        errno = EAGAIN
        return -1
    }

    // MARK: - Private pump tasks

    private func outboundPump() async {
        while !Task.isCancelled {
            guard let chunk = await takeOutboundChunk() else { break }
            do {
                try await transport.send(chunk)
            } catch {
                // Transport send failed; record it through the same inbound entry point the
                // transport uses, so cRecv() returns ECONNRESET after any buffered bytes.
                applyInbound(.failure(error))
                break
            }
        }
    }

    /// Waits for the next outbound chunk. Returns `nil` when the bridge is closed or the
    /// Task is cancelled, allowing the outbound pump to exit cleanly.
    ///
    /// All `NSLock` calls are delegated to synchronous helpers (`dequeueFirstOutbound()`,
    /// `storeContinuationOrDequeue(_:)`, `swapOutboundContinuation()`) — per CLAUDE.md, calling
    /// `NSLock.lock()` directly in an async function body is forbidden.
    private func takeOutboundChunk() async -> Data? {
        // Fast path: synchronous helper wraps the lock (no direct lock() in async body).
        switch dequeueFirstOutbound() {
        case .data(let chunk): return chunk
        case .closed: return nil
        case .empty: break
        }

        // Slow path: suspend until `enqueueOutbound(_:)` or `close()` resumes us.
        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                    // Re-check state under lock via a synchronous helper.
                    self.storeContinuationOrDequeue(cont)
                }
            },
            onCancel: { [self] in
                // onCancel runs synchronously on an arbitrary thread; NSLock is safe here.
                swapOutboundContinuation()?.resume(returning: nil)
            }
        )
    }

    // Result type for the synchronous fast-path dequeue helper.
    private enum OutboundDequeueResult {
        case data(Data)
        case closed
        case empty
    }

    /// Synchronous fast-path: dequeue the first outbound chunk under the lock.
    /// Must not be called from an async context directly — only via `takeOutboundChunk()`.
    private func dequeueFirstOutbound() -> OutboundDequeueResult {
        lock.lock()
        defer { lock.unlock() }
        if let first = outboundQueue.first {
            outboundQueue.removeFirst()
            return .data(first)
        }
        return isClosed ? .closed : .empty
    }

    /// Synchronous slow-path: under the lock, either dequeue a pending chunk and resume `cont`
    /// immediately, or store `cont` for `enqueueOutbound(_:)` / `close()` to resume later.
    private func storeContinuationOrDequeue(_ cont: CheckedContinuation<Data?, Never>) {
        lock.lock()
        if let first = outboundQueue.first {
            outboundQueue.removeFirst()
            lock.unlock()
            cont.resume(returning: first)
        } else if isClosed || Task.isCancelled {
            lock.unlock()
            cont.resume(returning: nil)
        } else {
            outboundContinuation = cont
            lock.unlock()
        }
    }

    // MARK: - Private lock helpers (all synchronous, no await)

    private func enqueueOutbound(_ data: Data) {
        lock.lock()
        if let cont = outboundContinuation {
            // Deliver directly to the waiting pump, bypassing the queue.
            outboundContinuation = nil
            lock.unlock()
            cont.resume(returning: data) // outside the lock
        } else {
            outboundQueue.append(data)
            lock.unlock()
        }
    }

    /// Records one delivery in the inbound store and fires the inbound-ready signal.
    ///
    /// The bridge keeps exactly one guard — `isClosed` — and deliberately no terminal-once flag
    /// of its own: `cRecv`'s return precedence (closed → bytes → EOF → error → would-block) stays
    /// byte-for-byte what it was, and terminal-once is the conformer's obligation (design D2).
    private func applyInbound(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !isClosed else {
            // The bridge is gone: cRecv answers ECONNRESET regardless, and no signal may fire
            // after `_onInboundReady` was cleared.
            lock.unlock()
            return
        }
        switch result {
        case .success(let data) where !data.isEmpty:
            // Enqueue by reference (the bytes are already owned — copied out of the NIO
            // ByteBuffer at the transport boundary), avoiding a second full-payload copy. Empty
            // chunks never reach here, so the FIFO head always has unconsumed bytes (cRecv's
            // loop invariant).
            InboundSignposts.chunk(bytes: data.count)
            inboundChunks.append(data)
            inboundCount += data.count
        case .success:
            inboundEOF = true
        case .failure(let error):
            inboundError = error
        }
        let handler = _onInboundReady
        lock.unlock()
        handler?()
    }

    /// Atomically swaps out the outbound continuation. Thread-safe (called from onCancel).
    private func swapOutboundContinuation() -> CheckedContinuation<Data?, Never>? {
        lock.lock()
        let cont = outboundContinuation
        outboundContinuation = nil
        lock.unlock()
        return cont
    }
}

#endif // canImport(Network)
