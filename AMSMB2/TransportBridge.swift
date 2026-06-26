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
/// **Inbound path** (peer → libsmb2): The inbound pump `Task` calls `transport.receive()` and
/// appends results to the inbound buffer. The C `recv` callback drains synchronously from that
/// buffer, returning the would-block signal when the buffer is empty and the transport is open.
///
/// **Concurrency model** (design D3): All mutable state is guarded by `NSLock`. Lock sections
/// never contain `await`; async work happens outside the locked sections.
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

    /// Bytes received from the transport but not yet consumed by the C recv callback.
    private var inboundBuffer = Data()
    /// Set when `transport.receive()` returns empty Data (graceful peer close).
    private var inboundEOF = false
    /// Set when the transport throws an error.
    private var inboundError: (any Error)?

    // MARK: - Outbound state (libsmb2 → transport)

    /// Byte chunks enqueued by `cSend()` and drained by the outbound pump.
    private var outboundQueue: [Data] = []
    /// Continuation suspended in `takeOutboundChunk()`, resumed by `enqueueOutbound(_:)`.
    private var outboundContinuation: CheckedContinuation<Data?, Never>?

    // MARK: - Lifecycle state

    /// Set by `close()`. Causes `cRecv()` to return ECONNRESET and terminates pump tasks.
    private var isClosed = false

    // MARK: - Pump tasks

    private var outboundPumpTask: Task<Void, Never>?
    private var inboundPumpTask: Task<Void, Never>?

    // MARK: - Init

    init(transport: any SMBTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    /// Starts both the outbound-drain and inbound-fill pump Tasks.
    /// Must be called after the transport has been connected.
    func startPumps() {
        startOutboundPump()
        startInboundPump()
    }

    /// Starts only the outbound pump (libsmb2 → transport direction).
    /// Used in unit tests that need to verify outbound delivery without the inbound pump
    /// competing for `transport.receive()` — see MockTransport loopback semantics.
    func startOutboundPump() {
        outboundPumpTask = Task { [self] in await outboundPump() }
    }

    /// Starts only the inbound pump (transport → libsmb2 direction).
    func startInboundPump() {
        inboundPumpTask = Task { [self] in await inboundPump() }
    }

    /// Tears down the bridge: marks closed, cancels pump tasks, and fires `transport.close()`
    /// in a background Task. Idempotent — safe to call more than once.
    /// Called from the C close trampoline.
    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let pendingContinuation = outboundContinuation
        outboundContinuation = nil
        lock.unlock()

        // Resume any waiting outbound pump outside the lock to avoid priority inversion.
        pendingContinuation?.resume(returning: nil)

        outboundPumpTask?.cancel()
        inboundPumpTask?.cancel()

        // transport.close() is async; fire-and-forget. Captures transport (not self) so the
        // bridge's own retain count does not prolong the Task's lifetime unnecessarily.
        let closingTransport = transport
        Task { await closingTransport.close() }
    }

    /// Produces a `smb2_external_transport` struct whose four C function pointers delegate to
    /// this bridge and whose `userdata` is `Unmanaged.passRetained(self).toOpaque()`.
    ///
    /// - Important: Call exactly once per bridge. The retained reference is balanced in the
    ///   C close trampoline via `takeRetainedValue()`.
    func makeExternalTransport() -> smb2_external_transport {
        var ext = smb2_external_transport()
        ext.userdata = Unmanaged.passRetained(self).toOpaque()

        // Non-capturing closures assigned to C function pointer fields.
        // Each recovers the bridge from `userdata` via Unmanaged (design D5).

        ext.connect = { userdata, host, port -> Int32 in
            guard let userdata else { return -1 }
            let bridge = Unmanaged<TransportBridge>.fromOpaque(userdata).takeUnretainedValue()
            bridge.kickConnect(
                host: host.map { String(cString: $0) } ?? "",
                port: Int(port)
            )
            return 0
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
            // ARC takes over the returned `bridge` local; on scope exit ARC releases it,
            // completing the balanced release.
            let bridge = Unmanaged<TransportBridge>.fromOpaque(userdata).takeRetainedValue()
            bridge.close()
            return 0
        }

        return ext
    }

    // MARK: - C callback implementations (internal for testability)

    /// Called from the C connect trampoline. Fires `transport.connect(host:port:)` async.
    /// The connect result is ignored here; T6's servicing loop handles connect errors.
    func kickConnect(host: String, port: Int) {
        let connectingTransport = transport
        Task { try? await connectingTransport.connect(host: host, port: port) }
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

        if !inboundBuffer.isEmpty {
            let count = min(maxLen, inboundBuffer.count)
            // Synchronous copy into C buffer — no await (design D4, CLAUDE.md constraint).
            inboundBuffer.withUnsafeBytes { rawSrc in
                guard let src = rawSrc.baseAddress else { return }
                buf.update(from: src.assumingMemoryBound(to: UInt8.self), count: count)
            }
            inboundBuffer.removeSubrange(..<count)
            return Int32(count)
        }

        if inboundEOF { return 0 }

        if inboundError != nil {
            errno = ECONNRESET
            return -1
        }

        // Would-block: inbound buffer is empty and the transport is still open.
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
                // Transport send failed; mark so cRecv() returns ECONNRESET.
                setInboundError(error)
                break
            }
        }
    }

    private func inboundPump() async {
        while !Task.isCancelled {
            let data: Data
            do {
                data = try await transport.receive()
            } catch {
                setInboundError(error)
                return
            }
            if data.isEmpty {
                setInboundEOF()
                return
            }
            appendInbound(data)
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
    private enum OutboundDequeueResult { case data(Data), closed, empty }

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

    private func appendInbound(_ data: Data) {
        lock.lock()
        inboundBuffer.append(data)
        lock.unlock()
    }

    private func setInboundEOF() {
        lock.lock()
        inboundEOF = true
        lock.unlock()
    }

    private func setInboundError(_ error: any Error) {
        lock.lock()
        inboundError = error
        lock.unlock()
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
