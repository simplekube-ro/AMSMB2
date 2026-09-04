//
//  Context.swift
//  AMSMB2
//
//  Created by Amir Abbas on 5/20/18.
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation
import SMB2

/// Fixed-capacity raw memory buffer managed by `BufferPool`.
/// The pointer is stable for the lifetime of the `RawBuffer` — safe to pass
/// to C APIs that hold it across async suspension points.
struct RawBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let capacity: Int

    fileprivate init(capacity: Int) {
        self.pointer = .allocate(byteCount: capacity, alignment: 1)
        self.capacity = capacity
    }

    fileprivate func deallocate() {
        pointer.deallocate()
    }

    /// Creates a `Data` by copying `count` bytes from the buffer.
    func data(count: Int) -> Data {
        Data(bytes: pointer, count: min(count, capacity))
    }
}

/// Reusable fixed-capacity buffer pool. Avoids per-operation allocation by
/// recycling `RawBuffer` instances between calls. Thread-safe via an internal lock.
final class BufferPool: @unchecked Sendable {
    private var pool: [RawBuffer] = []
    private let maxPoolSize: Int
    private let poolLock = NSLock()

    init(maxPoolSize: Int = 8) {
        self.maxPoolSize = maxPoolSize
    }

    /// Returns a buffer of at least `minimumSize` bytes.
    /// Prefers a pooled buffer that is already large enough; otherwise
    /// deallocates the most-recently-returned pooled buffer and allocates fresh.
    func checkout(minimumSize: Int) -> RawBuffer {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let index = pool.lastIndex(where: { $0.capacity >= minimumSize }) {
            return pool.remove(at: index)
        }
        // No buffer large enough — discard any pooled buffer and allocate fresh.
        if let index = pool.indices.last {
            pool.remove(at: index).deallocate()
        }
        return RawBuffer(capacity: minimumSize)
    }

    /// Abandons a buffer without returning it to the pool.
    ///
    /// Use this on error/cancellation paths where libsmb2 still holds the buffer
    /// pointer and may write into it after the Swift caller has thrown. Returning
    /// the buffer to the pool in that situation would cause data corruption if
    /// another operation checked it out; deallocating it would cause a
    /// use-after-free. Intentional leak is the only safe choice — it is bounded
    /// to one buffer per cancelled read operation.
    func abandon(_ buffer: RawBuffer) {
        // Deliberately does not call buffer.deallocate() or pool it.
        // The C callback still owns the pointer; we simply forget it.
    }

    /// Returns a buffer to the pool. Buffers beyond `maxPoolSize` are deallocated.
    func checkin(_ buffer: RawBuffer) {
        poolLock.lock()
        defer { poolLock.unlock() }
        guard pool.count < maxPoolSize else {
            buffer.deallocate()
            return
        }
        pool.append(buffer)
    }

    deinit {
        for buffer in pool { buffer.deallocate() }
    }
}

/// Provides synchronous operations on SMB2.
///
/// Thread safety: `SMB2Client` is `@unchecked Sendable`. All operations that touch
/// the underlying `smb2_context` are serialized through a dedicated serial
/// `DispatchQueue` (the "event loop"). Socket I/O is driven by `DispatchSource`
/// for efficient, non-blocking operation handling. Multiple operations can be
/// in-flight simultaneously — each caller waits on its own semaphore while the
/// event loop services all pending requests concurrently.
public final class SMB2Client: CustomDebugStringConvertible, CustomReflectable, @unchecked Sendable {
    private var context: UnsafeMutablePointer<smb2_context>?

    /// Serial queue that exclusively owns the smb2_context.
    /// All libsmb2 calls must execute on this queue.
    let eventLoopQueue: DispatchQueue

    /// Used to detect re-entrant calls to the event loop queue and avoid deadlocks.
    // Immutable process-wide identity token, set once at static init and never mutated; the per-queue
    // boolean lives in DispatchQueue specific storage, not the key (design D-3). On Apple platforms
    // `DispatchSpecificKey` is `Sendable`, so a plain `let` is concurrency-safe; on Linux (swift 6.1)
    // it is not yet `Sendable`, so `nonisolated(unsafe)` launders the safe-but-unconformed token.
    #if canImport(Darwin)
    private static let queueKey = DispatchSpecificKey<Bool>()
    #else
    private static nonisolated(unsafe) let queueKey = DispatchSpecificKey<Bool>()
    #endif

    /// DispatchSource-based socket monitor, created after connect. This is the legacy
    /// libsmb2-owned TCP path. On Apple the NIO transport seam replaces it entirely, so it is
    /// compiled only on non-`Network` platforms (Linux). See the `#else` branches throughout
    /// this file that pair with `#if canImport(Network)` for the seam.
    #if !canImport(Network)
    private var socketMonitor: SocketMonitor?
    #endif

    #if canImport(Network)
    /// The bridge active when an external-transport seam is in use. Nil on the legacy path.
    private var transportBridge: TransportBridge?
    /// Set to `true` after a successful seam-based connect. `smb2_get_fd()` is always -1
    /// while the seam is active; `isConnected` checks this flag on Apple platforms.
    private var seamConnected = false
    /// Pending timer work-item for `smb2_service_timeout`. Rescheduled after each service pass;
    /// cancelled on seam teardown to prevent use-after-free.
    private var pendingTimeoutItem: DispatchWorkItem?
    /// Inbound-ready debounce flag. `true` while a `serviceContextForSeam` pass is scheduled but
    /// has not yet started draining. Set under `serviceFlagLock` by `consumeInboundReadySignal()`
    /// (the bridge's inbound-ready callback) and cleared by `beginServicePass()` at the start of
    /// the queued pass. Collapses a burst of per-chunk inbound signals into a single dispatch.
    private var servicePending = false
    /// Guards `servicePending`. Separate from `eventLoopQueue` so the off-queue inbound-ready
    /// callback can make the debounce decision without a queue hop.
    private let serviceFlagLock = NSLock()
    #endif

    /// Tracks all pending operations for error broadcast on connection drop.
    private var pendingOperations: [ObjectIdentifier: CBData] = [:]

    /// Reusable buffer pool shared across all read operations on this client.
    let bufferPool = BufferPool()

    var timeout: TimeInterval

    /// Serializes libsmb2's process-global context registry (`active_contexts`) and the
    /// static counter inside `smb2_init_context` — neither of which libsmb2 locks (see
    /// `SMB2_LIST_ADD`/`SMB2_LIST_REMOVE` in init.c). Every SMB2 context in this library is
    /// created and destroyed through `createContext`/`destroyContext`, so this lock fully
    /// orders create/destroy across the independent per-context event-loop queues and
    /// prevents the global-list corruption that crashes inside `smb2_destroy_context`.
    private static let globalContextLock = NSLock()

    /// Allocates an `smb2_context` under ``globalContextLock`` so the `SMB2_LIST_ADD` into
    /// the global registry is serialized against every other create/destroy.
    private static func createContext() throws -> UnsafeMutablePointer<smb2_context> {
        globalContextLock.lock()
        defer { globalContextLock.unlock() }
        return try smb2_init_context().unwrap()
    }

    /// Destroys an `smb2_context` under ``globalContextLock`` so the `SMB2_LIST_REMOVE` from
    /// the global registry is serialized against every other create/destroy.
    private static func destroyContext(_ context: UnsafeMutablePointer<smb2_context>) {
        globalContextLock.lock()
        defer { globalContextLock.unlock() }
        smb2_destroy_context(context)
    }

    internal init(timeout: TimeInterval) throws {
        let ctx = try Self.createContext()
        self.context = ctx
        self.timeout = timeout
        self.eventLoopQueue = DispatchQueue(
            label: "smb2_eventloop_\(UInt(bitPattern: ctx))",
            qos: .userInitiated
        )
        self.eventLoopQueue.setSpecific(key: Self.queueKey, value: true)
    }

    /// All teardown runs on the event loop queue so that SocketMonitor.cancel() and
    /// smb2_destroy_context() are serialized with any in-flight I/O callbacks.
    private func shutdown() {
        #if canImport(Network)
        teardownSeam()
        #else
        socketMonitor?.cancel()
        socketMonitor = nil
        #endif
        if let ctx = context, smb2_get_fd(ctx) >= 0 {
            // Best-effort graceful disconnect: queue the FIN PDU and flush it once.
            //
            // This emission now runs BEFORE `failAllPendingOperations` (it used to follow it).
            // Safe at `deinit`: `async_await` / `async_await_pdu` / `connectWithBridge` are
            // instance methods, so a suspended caller's frame holds a strong `self` and `deinit`
            // cannot have started — every CBData still pending here was already abandoned by a
            // cancel or a timeout.
            smb2_disconnect_share_async(ctx, SMB2Client.generic_handler_noop, nil)
            smb2_service(ctx, Int32(POLLOUT))
        }
        failPendingAndDestroyContext(with: POSIXError(.ECANCELED))
    }

    /// Fails every pending operation with `error` (marking each abandoned) and then destroys the
    /// context if it is still alive. Must run on `eventLoopQueue`.
    ///
    /// The two statements MUST stay adjacent and in this order. Abandoning first is what makes
    /// every callback libsmb2 fires from `smb2_destroy_context`'s teardown sweep take
    /// `generic_handler`'s `isAbandoned` early return instead of resuming an already-resumed
    /// continuation — and that early return is in turn what keeps the `[weak self]` capture in the
    /// `cb.dataHandler` wrappers from ever being observed nil during `deinit` (Swift zeroes weak
    /// references once deallocation has begun). Do not "simplify" this by destroying first.
    ///
    /// Every path that destroys the context (deinit, `disconnect()`, and the `smb2_service`
    /// error branches) routes through here, so the `if let` guard covers a caller whose earlier
    /// step already ran it.
    private func failPendingAndDestroyContext(with error: any Error) {
        failAllPendingOperations(with: error)
        if let ctx = context {
            Self.destroyContext(ctx)
            context = nil
        }
    }

    deinit {
        guard context != nil else { return }
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            shutdown()
        } else {
            eventLoopQueue.sync { self.shutdown() }
        }
    }

    /// Raw context pointer for internal module use.
    /// Only safe to access from the event loop queue or from callbacks fired by smb2_service.
    var rawContext: UnsafeMutablePointer<smb2_context>? { context }

    /// Executes a closure synchronously on the event loop queue.
    /// Used for simple property access; do not use for async I/O operations.
    func withContext<R>(_ handler: (UnsafeMutablePointer<smb2_context>) throws -> R) throws -> R {
        var result: Result<R, any Error>!
        eventLoopQueue.sync {
            do {
                result = .success(try handler(context.unwrap()))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    /// Dispatches a closure to the event loop queue without waiting.
    /// Used for cleanup in deinit paths where the caller cannot block.
    /// Captures `self` strongly so the context liveness check is coherent.
    func fireAndForget(_ handler: @Sendable @escaping (UnsafeMutablePointer<smb2_context>) -> Void) {
        eventLoopQueue.async { [self] in
            guard let ctx = self.context else { return }
            handler(ctx)
        }
    }

    public var debugDescription: String {
        let pairs = customMirror.children.map { "\($0.label ?? "_"): \($0.value)" }
        return "SMB2Client(\(pairs.joined(separator: ", ")))"
    }

    public var customMirror: Mirror {
        var c: [(label: String?, value: Any)] = []
        if context != nil, let server {
            c.append((label: "server", value: server))
            c.append((label: "securityMode", value: securityMode))
            c.append((label: "authentication", value: authentication))
            clientGuid.map { c.append((label: "clientGuid", value: $0)) }
            c.append((label: "user", value: user))
            c.append((label: "version", value: version))
        }
        c.append((label: "isConnected", value: isConnected))
        c.append((label: "timeout", value: timeout))

        let m = Mirror(self, children: c, displayStyle: .class)
        return m
    }
}

// MARK: - Socket Monitor

extension SMB2Client {
    // The legacy DispatchSource socket-monitoring path drives libsmb2's built-in TCP socket.
    // On Apple the seam (no-fd servicing loop) replaces it, so this whole block compiles only
    // on non-`Network` platforms (Linux). Guard-not-delete: Linux is the sole remaining consumer.
    #if !canImport(Network)
    /// Monitors a socket file descriptor using `DispatchSource`.
    /// All methods must be called on the event loop queue.
    private final class SocketMonitor {
        private let readSource: any DispatchSourceRead
        private var writeSource: (any DispatchSourceWrite)?
        private var writeSourceResumed = false
        private let fd: Int32
        private let queue: DispatchQueue
        private let onEvent: () -> Void

        init(fd: Int32, queue: DispatchQueue, onEvent: @escaping () -> Void) {
            self.fd = fd
            self.queue = queue
            self.onEvent = onEvent

            self.readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            readSource.setEventHandler { [weak self] in self?.onEvent() }
            readSource.resume()
        }

        /// Enables or disables the write source based on whether libsmb2 has pending outgoing data.
        func activateWriteSourceIfNeeded(context: UnsafeMutablePointer<smb2_context>) {
            let needsWrite = (smb2_which_events(context) & Int32(POLLOUT)) != 0

            if needsWrite && !writeSourceResumed {
                if writeSource == nil {
                    writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    writeSource?.setEventHandler { [weak self] in self?.onEvent() }
                }
                writeSource?.resume()
                writeSourceResumed = true
            } else if !needsWrite && writeSourceResumed {
                writeSource?.suspend()
                writeSourceResumed = false
            }
        }

        func cancel() {
            readSource.cancel()
            if let writeSource {
                if !writeSourceResumed {
                    // DispatchSource must be resumed before it can be cancelled.
                    writeSource.resume()
                }
                writeSource.cancel()
            }
            writeSource = nil
        }
    }

    /// Invoked by SocketMonitor when the socket has I/O events.
    /// Runs on the event loop queue.
    private func handleSocketEvent() {
        guard let context else { return }

        let events = smb2_which_events(context)
        var pfd = pollfd()
        pfd.fd = smb2_get_fd(context)
        pfd.events = Int16(truncatingIfNeeded: events)

        // Non-blocking poll to confirm readiness; fall back to POLLIN if the source
        // fired before the kernel updated poll state.
        let revents: Int32
        if poll(&pfd, 1, 0) > 0 {
            revents = Int32(pfd.revents)
        } else {
            revents = Int32(POLLIN)
        }

        guard revents != 0 else { return }

        let result = smb2_service(context, revents)
        if result < 0 {
            let errorMsg = error
            stopSocketMonitoring()
            failPendingAndDestroyContext(with: POSIXError(.ECONNRESET, description: errorMsg))
            return
        }

        socketMonitor?.activateWriteSourceIfNeeded(context: context)
    }

    private func startSocketMonitoring() {
        guard let context else { return }
        let fd = smb2_get_fd(context)
        guard fd >= 0 else { return }

        socketMonitor = SocketMonitor(fd: fd, queue: eventLoopQueue) { [weak self] in
            self?.handleSocketEvent()
        }
        socketMonitor?.activateWriteSourceIfNeeded(context: context)
    }

    private func stopSocketMonitoring() {
        socketMonitor?.cancel()
        socketMonitor = nil
    }
    #endif // !canImport(Network)

    /// Routes post-operation servicing to the correct path: the seam no-fd loop (Apple) or the
    /// legacy `SocketMonitor` (fd-based, non-`Network` platforms). Must be called on
    /// `eventLoopQueue`.
    private func activateServicingAfterOperation(context: UnsafeMutablePointer<smb2_context>) {
        #if canImport(Network)
        if transportBridge != nil {
            flushOutboundForSeam(context: context)
            scheduleSeamTimeout()
        }
        #else
        socketMonitor?.activateWriteSourceIfNeeded(context: context)
        #endif
    }

    /// Fails all in-flight operations. `isAbandoned` is set before resuming so that
    /// any concurrent libsmb2 callback skips the already-resumed continuation.
    private func failAllPendingOperations(with error: any Error) {
        for (_, cb) in pendingOperations {
            cb.isAbandoned = true
            cb.error = error
            cb.isFinished = true
            if let continuation = cb.continuation {
                cb.continuation = nil
                continuation.resume(throwing: error)
            }
        }
        pendingOperations.removeAll()
    }
}

// MARK: Setting manipulation

extension SMB2Client {
    private func syncOnEventLoop<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            return work()
        } else {
            return eventLoopQueue.sync { work() }
        }
    }

    var workstation: String {
        get {
            syncOnEventLoop { (context?.pointee.workstation).map(String.init(cString:)) ?? "" }
        }
        set {
            eventLoopQueue.sync {
                guard let context else { return }
                smb2_set_workstation(context, newValue)
            }
        }
    }

    var domain: String {
        get {
            syncOnEventLoop { (context?.pointee.domain).map(String.init(cString:)) ?? "" }
        }
        set {
            eventLoopQueue.sync {
                guard let context else { return }
                smb2_set_domain(context, newValue)
            }
        }
    }

    var user: String {
        get {
            syncOnEventLoop { (context?.pointee.user).map(String.init(cString:)) ?? "" }
        }
        set {
            eventLoopQueue.sync {
                guard let context else { return }
                smb2_set_user(context, newValue)
            }
        }
    }

    var password: String {
        get {
            syncOnEventLoop { (context?.pointee.password).map(String.init(cString:)) ?? "" }
        }
        set {
            eventLoopQueue.sync {
                guard let context else { return }
                smb2_set_password(context, newValue != "" ? newValue : nil)
            }
        }
    }

    var securityMode: NegotiateSigning {
        get {
            syncOnEventLoop {
                (context?.pointee.security_mode).flatMap(NegotiateSigning.init(rawValue:)) ?? []
            }
        }
        set {
            eventLoopQueue.sync {
                guard let context else { return }
                smb2_set_security_mode(context, newValue.rawValue)
            }
        }
    }

    var seal: Bool {
        get {
            syncOnEventLoop { context?.pointee.seal ?? 0 != 0 }
        }
        set {
            eventLoopQueue.sync {
                guard let context else { return }
                smb2_set_seal(context, newValue ? 1 : 0)
            }
        }
    }

    var authentication: Security {
        get {
            syncOnEventLoop { context?.pointee.sec ?? .undefined }
        }
        set {
            eventLoopQueue.sync {
                guard let context else { return }
                smb2_set_authentication(context, .init(bitPattern: newValue.rawValue))
            }
        }
    }

    var clientGuid: UUID? {
        syncOnEventLoop {
            guard let guid = try? smb2_get_client_guid(context.unwrap()) else {
                return nil
            }
            let uuid = UnsafeRawPointer(guid).assumingMemoryBound(to: uuid_t.self).pointee
            return UUID(uuid: uuid)
        }
    }

    var server: String? {
        syncOnEventLoop { context?.pointee.server.map(String.init(cString:)) }
    }

    var share: String? {
        syncOnEventLoop { context?.pointee.share.map(String.init(cString:)) }
    }

    var version: Version {
        syncOnEventLoop {
            (context?.pointee.dialect).map { Version(rawValue: UInt32($0)) } ?? .any
        }
    }

    var passthrough: Bool {
        get {
            syncOnEventLoop {
                var result: Int32 = 0
                smb2_get_passthrough(context, &result)
                return result != 0
            }
        }
        set {
            eventLoopQueue.sync {
                smb2_set_passthrough(context, newValue ? 1 : 0)
            }
        }
    }

    var isConnected: Bool {
        // Read seam/fd state on the event loop queue so `seamConnected` (mutated only on
        // `eventLoopQueue`) is never read concurrently from an off-queue async caller
        // (e.g. `echo()`, `Optional.unwrap()`). Nested `syncOnEventLoop` is reentrant-safe
        // via `queueKey`, so the inner `fileDescriptor` access stays correct.
        syncOnEventLoop {
            #if canImport(Network)
            if seamConnected { return true }
            #endif
            return fileDescriptor != -1
        }
    }

    var fileDescriptor: Int32 {
        syncOnEventLoop {
            do {
                return try smb2_get_fd(context.unwrap())
            } catch {
                return -1
            }
        }
    }

    /// Number of operations currently registered in the pending table, read on the serialized
    /// event-loop queue. Platform-neutral: the pending table backs BOTH the seam and the legacy
    /// fd path, so this accessor is available on every platform (the name is kept for its
    /// existing seam call sites). Used by the seam acceptance tests to assert that a cancelled
    /// or timed-out operation is removed (no leaked continuation / pending op), satisfying the
    /// connect-ordering spec's teardown requirements, and by the disconnect-reclaim tests to
    /// wait until an operation is actually queued.
    var pendingSeamOperationCount: Int {
        syncOnEventLoop { pendingOperations.count }
    }

    #if canImport(Network)
    /// Whether a seam `TransportBridge` is currently installed (read on the serialized
    /// event-loop queue). Used by the D12 bridge-ownership tests to assert that a cancellation
    /// or eager-failure win leaves no installed bridge (`transportBridge == nil`).
    var hasInstalledSeamBridge: Bool {
        syncOnEventLoop { transportBridge != nil }
    }
    #endif

    var error: String? {
        smb2_get_error(context).map(String.init(cString:))
    }

    var ntError: NTStatus {
        .init(rawValue: smb2_get_nterror(context))
    }

    var errno: Int32 {
        ntError.posixErrorCode.rawValue
    }

    var maximumTransactionSize: Int {
        syncOnEventLoop {
            (context?.pointee.max_transact_size).map(Int.init) ?? 65535
        }
    }
}

// MARK: Connectivity

extension SMB2Client {
    #if !canImport(Network)
    /// Legacy libsmb2-owned TCP connect. Compiled only on non-`Network` platforms (Linux); on
    /// Apple `connect(server:share:user:transportKind:)` (the seam) is the sole connect path.
    func connect(server: String, share: String, user: String) async throws {
        // Connect uses a temporary poll loop on the event loop queue because
        // DispatchSource can't be created until the socket fd exists.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.eventLoopQueue.async {
                do {
                    guard let context = self.context else {
                        throw POSIXError(.ENOTCONN)
                    }
                    let cb = CBData()
                    let cbPtr = Unmanaged.passRetained(cb).toOpaque()
                    let result = smb2_connect_share_async(
                        context, server, share, user, SMB2Client.generic_handler, cbPtr
                    )
                    if result < 0 {
                        // Callback was never registered; balance the retain ourselves.
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        try POSIXError.throwIfError(result, description: self.error)
                    }
                    try self.pollUntilComplete(cb)
                    try POSIXError.throwIfError(cb.result, description: self.error)
                    self.startSocketMonitoring()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    #endif // !canImport(Network)

    /// Disconnects the client and reclaims its SMB2 context.
    ///
    /// - Important: This is **terminal** for the instance. After it returns the client holds no
    ///   context, so it cannot be reconnected and every subsequent operation — including one
    ///   issued through an `SMB2FileHandle` or `SMB2Directory` opened before the disconnect —
    ///   fails immediately with `POSIXError(.ENOTCONN)` rather than after the operation timeout.
    ///   To reconnect, construct a fresh `SMB2Client`; `SMB2Manager.connect(shareName:)` already
    ///   does this on every `connectShare`.
    ///
    /// Destroying the context here is what makes libsmb2 fire (and thereby balance) the retain it
    /// holds on every pending `CBData`, and what invokes the external transport's `close`
    /// trampoline so the seam bridge's `ext.userdata` retain is released too. Deferring either to
    /// `deinit` would leak them permanently whenever a reply never arrives.
    ///
    /// Calling it again is harmless: the context is already nil and nothing is destroyed twice.
    func disconnect() async {
        // Send a best-effort disconnect PDU and tear down in one atomic block
        // on the event loop queue.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.eventLoopQueue.async {
                #if canImport(Network)
                // Apple: the seam is the only transport. fd is always -1; the disconnect PDU
                // (when a seam is live) is queued via the outbound FIFO and flushed before
                // teardown.
                if self.seamConnected, let context = self.context {
                    smb2_disconnect_share_async(context, SMB2Client.generic_handler_noop, nil)
                    self.flushOutboundForSeam(context: context)
                }
                self.teardownSeam()
                self.failPendingAndDestroyContext(with: POSIXError(.ENOTCONN))
                continuation.resume()
                #else
                if let context = self.context, smb2_get_fd(context) >= 0 {
                    smb2_disconnect_share_async(context, SMB2Client.generic_handler_noop, nil)
                    smb2_service(context, Int32(POLLOUT))
                }
                self.stopSocketMonitoring()
                self.failPendingAndDestroyContext(with: POSIXError(.ENOTCONN))
                continuation.resume()
                #endif
            }
        }
    }

    func echo() async throws {
        if !isConnected {
            throw POSIXError(.ENOTCONN)
        }
        try await async_await { context, cbPtr -> Int32 in
            smb2_echo_async(context, SMB2Client.generic_handler, cbPtr)
        }
    }
}

// MARK: DCE-RPC

extension SMB2Client {
    func shareEnum() async throws -> [SMB2Share] {
        try await async_await(dataHandler: [SMB2Share].init) { context, cbPtr -> Int32 in
            smb2_share_enum_async(context, SHARE_INFO_1, SMB2Client.generic_handler, cbPtr)
        }.data
    }

    func shareEnumSwift() async throws -> [SMB2Share] {
        // Connection to server service.
        let srvsvc = try await SMB2FileHandle.open(path: "srvsvc", desiredAccess: [.read, .write], createDisposition: .open, on: self)
        // Bind command
        _ = try await srvsvc.write(data: MSRPC.SrvsvcBindData())
        let recvBindData = try await srvsvc.pread(offset: 0, length: Int(Int16.max))
        try MSRPC.validateBindData(recvBindData)

        // NetShareEnum request, Level 1 mean we need share name and remark.
        _ = try await srvsvc.pwrite(data: MSRPC.NetShareEnumAllRequest(serverName: try server.unwrap()), offset: 0)
        let recvData = try await srvsvc.pread(offset: 0)
        return try MSRPC.NetShareEnumAllLevel1(data: recvData).shares
    }
}

// MARK: File information

extension SMB2Client {
    func stat(_ path: String) async throws -> smb2_stat_64 {
        var st = smb2_stat_64()
        try await async_await { context, cbPtr -> Int32 in
            smb2_stat_async(context, path.canonical, &st, SMB2Client.generic_handler, cbPtr)
        }
        return st
    }

    func statvfs(_ path: String) async throws -> smb2_statvfs {
        var st = smb2_statvfs()
        try await async_await { context, cbPtr -> Int32 in
            smb2_statvfs_async(context, path.canonical, &st, SMB2Client.generic_handler, cbPtr)
        }
        return st
    }

    func readlink(_ path: String) async throws -> String {
        try await async_await(dataHandler: String.init) { context, cbPtr -> Int32 in
            smb2_readlink_async(context, path.canonical, SMB2Client.generic_handler, cbPtr)
        }.data
    }

    func symlink(_ path: String, to destination: String) async throws {
        let file = try await SMB2FileHandle.open(path: path, flags: O_RDWR | O_CREAT | O_EXCL | O_SYMLINK | O_SYNC, on: self)
        let reparse = IOCtl.SymbolicLinkReparse(path: destination, isRelative: true)
        try await file.fcntl(command: .setReparsePoint, args: reparse)
    }
}

// MARK: File operation

extension SMB2Client {
    func mkdir(_ path: String) async throws {
        try await async_await { context, cbPtr -> Int32 in
            smb2_mkdir_async(context, path.canonical, SMB2Client.generic_handler, cbPtr)
        }
    }

    func rmdir(_ path: String) async throws {
        try await async_await { context, cbPtr -> Int32 in
            smb2_rmdir_async(context, path.canonical, SMB2Client.generic_handler, cbPtr)
        }
    }

    func unlink(_ path: String, type: smb2_stat_64.ResourceType = .file) async throws {
        switch type {
        case .directory:
            throw POSIXError(.EINVAL, description: "Use rmdir() to delete a directory.")
        case .file:
            try await async_await { context, cbPtr -> Int32 in
                smb2_unlink_async(context, path.canonical, SMB2Client.generic_handler, cbPtr)
            }
        case .link:
            let file = try await SMB2FileHandle.open(path: path, flags: O_RDWR | O_SYMLINK, on: self)
            try await file.setInfo(smb2_file_disposition_info(delete_pending: 1), infoClass: .disposition)
        default:
            preconditionFailure("Not supported file type.")
        }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await async_await { context, cbPtr -> Int32 in
            smb2_rename_async(
                context, path.canonical, newPath.canonical, SMB2Client.generic_handler, cbPtr
            )
        }
    }

    func truncate(_ path: String, toLength: UInt64) async throws {
        try await async_await { context, cbPtr -> Int32 in
            smb2_truncate_async(
                context, path.canonical, toLength, SMB2Client.generic_handler, cbPtr
            )
        }
    }
}

// MARK: Async operation handler

extension SMB2Client {
    /// Per-operation callback state. Each in-flight operation gets its own `CBData`.
    /// `generic_handler` resumes the stored `CheckedContinuation` when libsmb2
    /// delivers the reply via `smb2_service`.
    ///
    /// `isAbandoned` prevents the continuation from being double-resumed when a timeout
    /// or connection drop races with the libsmb2 callback. `passRetained`/`takeRetainedValue`
    /// keeps the object alive until the callback fires.
    final class CBData: @unchecked Sendable {
        /// Serializes access to ``liveCount``. `CBData` instances are created and released from
        /// several execution contexts (caller task, `eventLoopQueue`, libsmb2 callbacks), so the
        /// counter needs its own lock.
        private static let liveCountLock = NSLock()
        /// `nonisolated(unsafe)`: EVERY read and write below goes through `liveCountLock`, so the
        /// storage is never touched unsynchronized. The lock — not the compiler — is the safety
        /// argument here, exactly as for the `globalContextLock`-guarded context registry.
        nonisolated(unsafe) private static var _liveCount = 0

        /// Number of `CBData` instances currently alive in the process. Used by the
        /// disconnect-reclaim regression tests to assert that every callback object registered
        /// with libsmb2 is released by the time `disconnect()` returns.
        ///
        /// Deliberately NOT wrapped in `#if DEBUG`, matching the existing unconditional test
        /// accessors `pendingSeamOperationCount` / `hasInstalledSeamBridge` (and keeping
        /// `swift test -c release` meaningful). The cost is two uncontended acquires of a
        /// process-global lock per operation (init + deinit), negligible next to a network
        /// round trip.
        ///
        /// Tests MUST compare against a baseline captured at test start, never against `0` —
        /// other tests in the same process may hold live instances.
        static var liveCount: Int {
            liveCountLock.withLock { _liveCount }
        }

        init() {
            Self.liveCountLock.withLock { Self._liveCount += 1 }
        }

        deinit {
            Self.liveCountLock.withLock { Self._liveCount -= 1 }
        }

        var result: Int32 = .init(NTStatus.success.rawValue)
        var dataHandler: ((UnsafeMutableRawPointer?) -> Void)?
        var error: (any Error)?
        /// Set to `true` when the caller has timed out, the connection was dropped,
        /// or the callback has already fired. Prevents double-resume of the continuation.
        var isAbandoned = false
        /// Set to `true` by the shared `generic_handler` (used by BOTH the legacy and seam
        /// connect paths). Consumed only by `pollUntilComplete` on the legacy/Linux connect
        /// path; on Apple (seam) the field is write-only — the seam servicing loop drives the
        /// handshake via the stored continuation instead. Intentionally left unguarded so the
        /// shared handler does not need a platform branch.
        var isFinished = false
        var status: NTStatus {
            NTStatus(rawValue: result)
        }

        /// Continuation resumed when the operation completes. Nil for the connect path
        /// (which uses `pollUntilComplete` instead).
        var continuation: CheckedContinuation<Void, any Error>?
        /// Cleanup closure that removes this CBData from `pendingOperations`.
        /// Called on the event loop queue before the continuation is resumed.
        var cleanup: (() -> Void)?
    }

    #if !canImport(Network)
    /// Poll loop used only during the legacy `connect()`, before DispatchSource monitoring is
    /// running. Runs synchronously on the event loop queue. Compiled only on non-`Network`
    /// platforms (Linux); the Apple seam drives its handshake through the no-fd servicing loop.
    private func pollUntilComplete(_ cb: CBData) throws {
        let startDate = Date()
        while cb.error == nil && !cb.isFinished {
            guard let context else {
                throw POSIXError(.ENOTCONN)
            }
            var pfd = pollfd()
            pfd.fd = smb2_get_fd(context)
            pfd.events = Int16(truncatingIfNeeded: smb2_which_events(context))

            if pfd.fd < 0 || (poll(&pfd, 1, 100) < 0 && Foundation.errno != EAGAIN) {
                throw POSIXError(.init(Foundation.errno), description: error)
            }

            if pfd.revents == 0 {
                if timeout > 0, Date().timeIntervalSince(startDate) > timeout {
                    throw POSIXError(.ETIMEDOUT)
                }
                continue
            }

            let result = smb2_service(context, Int32(pfd.revents))
            if result < 0 {
                let errorMsg = error
                failPendingAndDestroyContext(with: POSIXError(.ECONNRESET, description: errorMsg))
                throw POSIXError(.ECONNRESET, description: errorMsg)
            }
        }
        if let error = cb.error { throw error }
    }
    #endif // !canImport(Network)

    /// Callback invoked by libsmb2 when an async operation completes (on the event loop queue).
    /// `takeRetainedValue()` balances the `passRetained()` performed at setup.
    /// Resumes the stored `CheckedContinuation` to unblock the awaiting caller, or sets
    /// `isFinished` for the `pollUntilComplete` path (connect).
    ///
    /// Note: the original `fd >= 0` guard was removed so that seam operations — where fd is
    /// always -1 — also invoke their callbacks correctly. The `isAbandoned` check below is
    /// sufficient to prevent double-resume when `failAllPendingOperations` races with a
    /// callback fired by `smb2_destroy_context` during teardown.
    static let generic_handler: smb2_command_cb = { _, status, command_data, cbdata in
        do {
            let cbdata = Unmanaged<CBData>.fromOpaque(try cbdata.unwrap()).takeRetainedValue()
            guard !cbdata.isAbandoned else {
                // Last time anyone touches an abandoned CBData: libsmb2 has just handed back its
                // retain, so drop the closures here and release whatever they captured.
                cbdata.cleanup = nil
                cbdata.dataHandler = nil
                return
            }
            cbdata.isAbandoned = true
            if NTStatus(rawValue: status) != .success {
                cbdata.result = status
            }
            cbdata.dataHandler?(command_data)
            cbdata.dataHandler = nil
            cbdata.isFinished = true
            cbdata.cleanup?()
            cbdata.cleanup = nil
            if let continuation = cbdata.continuation {
                cbdata.continuation = nil
                continuation.resume()
            }
        } catch {}
    }

    /// No-op callback for fire-and-forget operations (e.g., close in deinit).
    static let generic_handler_noop: smb2_command_cb = { _, _, _, _ in }

    typealias ContextHandler<R> = (_ client: SMB2Client, _ dataPtr: UnsafeMutableRawPointer?)
        throws -> R
    typealias UnsafeContextHandler<R> = (
        _ context: UnsafeMutablePointer<smb2_context>, _ dataPtr: UnsafeMutableRawPointer?
    ) throws -> R

    @discardableResult
    func async_await(execute handler: @escaping UnsafeContextHandler<Int32>) async throws -> Int32 {
        try await async_await(dataHandler: { _, _ in }, execute: handler).result
    }

    /// Submits an async libsmb2 operation and suspends the calling task until the reply arrives.
    ///
    /// The libsmb2 call is dispatched onto the event loop queue (brief — just queues the PDU).
    /// The caller suspends via `CheckedContinuation`. When DispatchSource fires,
    /// `smb2_service` calls `generic_handler` which resumes the continuation.
    /// Multiple operations can be in-flight simultaneously, each with its own continuation.
    @discardableResult
    func async_await<DataType>(
        dataHandler: @escaping ContextHandler<DataType>,
        execute handler: @escaping UnsafeContextHandler<Int32>
    ) async throws -> (result: Int32, data: DataType) {
        // Fast-path: bail immediately if the Task is already cancelled.
        try Task.checkCancellation()

        let cb = CBData()
        var resultData: DataType?
        var dataHandlerError: (any Error)?
        // `[weak self]`: libsmb2 holds this CBData until the reply arrives or the context is
        // destroyed, so a strong capture would close the cycle
        // `smb2_context.waitqueue -> CBData -> SMB2Client -> context` and make the client
        // unreclaimable whenever a reply never comes (fix-disconnect-reclaims-context).
        // The weak reference is never observed nil in practice: `dataHandler` runs ONLY on
        // `generic_handler`'s non-abandoned branch, and every teardown that can destroy the
        // context from `deinit` fails (abandons) all pending operations first — see
        // `failPendingAndDestroyContext(with:)`.
        cb.dataHandler = { [weak self] ptr in
            guard let self else { return }
            do {
                resultData = try dataHandler(self, ptr)
            } catch {
                dataHandlerError = error
            }
        }
        let cbId = ObjectIdentifier(cb)
        // nonisolated(unsafe): `handler` must cross into the @Sendable block but is invoked exactly
        // once, on eventLoopQueue — the serial owner of smb2_context. Confinement makes the crossing
        // race-free; this asserts it rather than introducing shared-mutable state (design D-2).
        nonisolated(unsafe) let confinedHandler = handler

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.eventLoopQueue.async {
                    // Construct the opaque pointer locally to avoid capturing a non-Sendable
                    // UnsafeMutableRawPointer across the @Sendable boundary (see connectWithBridge).
                    // passRetained keeps CBData alive until generic_handler calls takeRetainedValue().
                    let cbPtr = Unmanaged.passRetained(cb).toOpaque()
                    guard let context = self.context else {
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        continuation.resume(throwing: POSIXError(.ENOTCONN))
                        return
                    }
                    do {
                        let result = try confinedHandler(context, cbPtr)
                        try POSIXError.throwIfError(result, description: self.error)
                        cb.continuation = continuation
                        // Check if cancellation arrived before this block ran.
                        // The onCancel handler sets isAbandoned but couldn't resume
                        // the continuation (it was nil at the time).
                        guard !cb.isAbandoned else {
                            cb.continuation = nil
                            // Do NOT release here: the PDU is already queued, so libsmb2 owns cbPtr
                            // and will fire generic_handler exactly once (on reply, or during
                            // smb2_destroy_context's teardown sweep), which performs the single
                            // balancing takeRetainedValue(). Releasing now would double-balance →
                            // use-after-free (fix-cbdata-cancel-race-uaf).
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        cb.cleanup = { [weak self] in
                            self?.pendingOperations.removeValue(forKey: cbId)
                        }
                        self.pendingOperations[cbId] = cb
                        self.activateServicingAfterOperation(context: context)

                        // Start timeout timer on the event loop queue.
                        if self.timeout > 0 {
                            self.eventLoopQueue.asyncAfter(deadline: .now() + self.timeout) { [weak self, weak cb] in
                                guard let cb, !cb.isAbandoned else { return }
                                cb.isAbandoned = true
                                self?.pendingOperations.removeValue(forKey: cbId)
                                if let cont = cb.continuation {
                                    cb.continuation = nil
                                    cont.resume(throwing: POSIXError(.ETIMEDOUT))
                                }
                            }
                        }
                    } catch {
                        // Reachable ONLY before the PDU is queued (the only throwing call above is
                        // the libsmb2 async/queue call itself, which registers nothing on failure).
                        // NEVER add a throwing call after smb2_*_async/smb2_queue_pdu success or
                        // this becomes the same double-free fixed in fix-cbdata-cancel-race-uaf.
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Remove the pending operation and resume with CancellationError.
            // Dispatched to event loop queue for thread safety.
            self.eventLoopQueue.async {
                guard !cb.isAbandoned else { return }
                cb.isAbandoned = true
                self.pendingOperations.removeValue(forKey: cbId)
                if let cont = cb.continuation {
                    cb.continuation = nil
                    cont.resume(throwing: CancellationError())
                }
            }
        }

        if let error = cb.error { throw error }
        let cbResult = cb.result
        try POSIXError.throwIfError(cbResult, description: error)
        if let error = dataHandlerError { throw error }
        return try (cbResult, resultData.unwrap())
    }

    @discardableResult
    func async_await_pdu(execute handler: @escaping UnsafeContextHandler<UnsafeMutablePointer<smb2_pdu>?>)
        async throws -> UInt32
    {
        try await async_await_pdu(dataHandler: { _, _ in }, execute: handler).status
    }

    @discardableResult
    func async_await_pdu<DataType>(
        dataHandler: @escaping ContextHandler<DataType>,
        execute handler: @escaping UnsafeContextHandler<UnsafeMutablePointer<smb2_pdu>?>
    ) async throws -> (status: UInt32, data: DataType) {
        try Task.checkCancellation()

        let cb = CBData()
        var resultData: DataType?
        var dataHandlerError: (any Error)?
        // `[weak self]`: libsmb2 holds this CBData until the reply arrives or the context is
        // destroyed, so a strong capture would close the cycle
        // `smb2_context.waitqueue -> CBData -> SMB2Client -> context` and make the client
        // unreclaimable whenever a reply never comes (fix-disconnect-reclaims-context).
        // The weak reference is never observed nil in practice: `dataHandler` runs ONLY on
        // `generic_handler`'s non-abandoned branch, and every teardown that can destroy the
        // context from `deinit` fails (abandons) all pending operations first — see
        // `failPendingAndDestroyContext(with:)`.
        cb.dataHandler = { [weak self] ptr in
            guard let self else { return }
            do {
                resultData = try dataHandler(self, ptr)
            } catch {
                dataHandlerError = error
            }
        }
        let cbId = ObjectIdentifier(cb)
        // nonisolated(unsafe): `handler` must cross into the @Sendable block but is invoked exactly
        // once, on eventLoopQueue — the serial owner of smb2_context. Confinement makes the crossing
        // race-free; this asserts it rather than introducing shared-mutable state (design D-2).
        nonisolated(unsafe) let confinedHandler = handler

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.eventLoopQueue.async {
                    // Construct the opaque pointer locally to avoid capturing a non-Sendable
                    // UnsafeMutableRawPointer across the @Sendable boundary (see connectWithBridge).
                    // passRetained keeps CBData alive until generic_handler calls takeRetainedValue().
                    let cbPtr = Unmanaged.passRetained(cb).toOpaque()
                    guard let context = self.context else {
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        continuation.resume(throwing: POSIXError(.ENOTCONN))
                        return
                    }
                    do {
                        let pdu = try confinedHandler(context, cbPtr).unwrap()
                        smb2_queue_pdu(context, pdu)
                        cb.continuation = continuation
                        // Check if cancellation arrived before this block ran.
                        // The onCancel handler sets isAbandoned but couldn't resume
                        // the continuation (it was nil at the time).
                        guard !cb.isAbandoned else {
                            cb.continuation = nil
                            // Do NOT release here: the PDU is already queued, so libsmb2 owns cbPtr
                            // and will fire generic_handler exactly once (on reply, or during
                            // smb2_destroy_context's teardown sweep), which performs the single
                            // balancing takeRetainedValue(). Releasing now would double-balance →
                            // use-after-free (fix-cbdata-cancel-race-uaf).
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        cb.cleanup = { [weak self] in
                            self?.pendingOperations.removeValue(forKey: cbId)
                        }
                        self.pendingOperations[cbId] = cb
                        self.activateServicingAfterOperation(context: context)

                        if self.timeout > 0 {
                            self.eventLoopQueue.asyncAfter(deadline: .now() + self.timeout) { [weak self, weak cb] in
                                guard let cb, !cb.isAbandoned else { return }
                                cb.isAbandoned = true
                                self?.pendingOperations.removeValue(forKey: cbId)
                                if let cont = cb.continuation {
                                    cb.continuation = nil
                                    cont.resume(throwing: POSIXError(.ETIMEDOUT))
                                }
                            }
                        }
                } catch {
                    // Reachable ONLY before the PDU is queued (the only throwing call above is the
                    // libsmb2 async/queue call itself, which registers nothing on failure). NEVER
                    // add a throwing call after smb2_*_async/smb2_queue_pdu success or this
                    // becomes the same double-free fixed in fix-cbdata-cancel-race-uaf.
                    Unmanaged<CBData>.fromOpaque(cbPtr).release()
                    continuation.resume(throwing: error)
                }
            }
        }
        } onCancel: {
            self.eventLoopQueue.async {
                guard !cb.isAbandoned else { return }
                cb.isAbandoned = true
                self.pendingOperations.removeValue(forKey: cbId)
                if let cont = cb.continuation {
                    cb.continuation = nil
                    cont.resume(throwing: CancellationError())
                }
            }
        }

        if let error = cb.error { throw error }
        try POSIXError.throwIfErrorStatus(cb.status)
        if let error = dataHandlerError { throw error }
        return try (cb.status.rawValue, resultData.unwrap())
    }
}

// MARK: - External-transport (seam) servicing loop

#if canImport(Network)

// MARK: - Bridge-ownership handoff (design D12)

/// Lock-protected bridge-ownership handoff for `connectWithBridge` (design D12).
///
/// Records exactly one bridge owner at every instant across the interval from before the eager
/// `bridge.connect` through seam installation:
/// `eagerConnecting → localOwned → installing → installed`, plus the terminal states `cancelled`
/// (cancellation won the claim, awaiting consumption by the eager-completion reconciliation or a
/// failed install claim) and `finished` (ownership consumed). Every transition is atomic, and —
/// mirroring D7's `resolveConnect` — the party that wins a transition performs the
/// associated close/cleanup duty *outside* the lock. The bridge therefore closes exactly once on
/// every path, and cancellation racing installation has a single lock-protected winner
/// (cancelled-first → local close, no libsmb2 call; installed-first → installed-seam teardown).
///
/// `@unchecked Sendable`: all mutable state is a single `State` guarded by `NSLock`; lock
/// sections never contain `await` (CLAUDE.md).
final class BridgeOwnershipHandoff: @unchecked Sendable {

    /// The bridge-ownership state (design D12).
    enum State: Equatable {
        case eagerConnecting
        case localOwned
        case installing
        case installed
        case cancelled
        case finished
    }

    /// Outcome of the eager-completion reconciliation (design D12 rows A–D + race E).
    enum ReconcileOutcome: Equatable {
        /// Row A — success while `eagerConnecting`: proceed toward installation, no close.
        case proceed
        /// Rows B/C (and race E cancellation-first): cancellation committed first — close the
        /// still-local bridge once and surface `CancellationError`.
        case cancellationWon
        /// Row D (and race E failure-first): ordinary eager failure — close once and rethrow the
        /// mapped original transport error.
        case eagerFailed
    }

    /// Duty assigned to the outer `onCancel` by `cancel()` (design D12).
    enum CancelDuty: Equatable {
        /// `eagerConnecting` (the reconciliation closes) or a terminal state (nothing to do).
        case noClose
        /// `localOwned`: close the still-local, not-yet-installed bridge exactly once.
        case closeLocalBridge
        /// `installing`/`installed`: route through the installed-ownership `teardownSeam()`.
        case installedTeardown
    }

    private let lock = NSLock()
    private var state: State = .eagerConnecting

    /// Test-only read of the current state — never used by production control flow.
    var currentState: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// `onCancel`: transitions the state and returns the close duty for the caller to perform
    /// outside the lock (design D12).
    func cancel() -> CancelDuty {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .eagerConnecting:
            state = .cancelled
            return .noClose
        case .localOwned:
            state = .cancelled
            return .closeLocalBridge
        case .installing, .installed:
            return .installedTeardown
        case .cancelled, .finished:
            return .noClose
        }
    }

    /// Eager-completion reconciliation: one lock-protected transition combining the handoff state
    /// and the connect result (design D12). Called exactly once, immediately after
    /// `bridge.connect` returns or throws.
    ///
    /// Precedence (race E): if cancellation already committed its `eagerConnecting → cancelled`
    /// transition before this claim, cancellation is caller-visible regardless of the connect
    /// result (rows B/C); otherwise the connect result decides (rows A/D).
    func reconcile(connectFailed: Bool) -> ReconcileOutcome {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .cancelled:
            state = .finished
            return .cancellationWon
        case .eagerConnecting:
            if connectFailed {
                state = .finished
                return .eagerFailed
            }
            state = .localOwned
            return .proceed
        case .localOwned, .installing, .installed, .finished:
            // Unreachable: reconcile is invoked exactly once, only from
            // `eagerConnecting`/`cancelled`. Surface a double-call/invalid-state regression in
            // debug builds; fall back to "proceed" (no duty) in release.
            assertionFailure("reconcile called twice or from invalid state \(state)")
            return .proceed
        }
    }

    /// The install block's first step: claim `localOwned → installing`. Returns `false` when
    /// cancellation already won (state `cancelled`), in which case the caller must create nothing
    /// and resume `CancellationError` (design D12).
    func claimInstalling() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if state == .localOwned {
            state = .installing
            return true
        }
        // Only `cancelled` is reachable here (onCancel won at `localOwned`).
        return false
    }

    /// Install succeeded up to ownership transfer into `transportBridge`: `installing → installed`.
    func markInstalled() {
        lock.lock()
        defer { lock.unlock() }
        if state == .installing { state = .installed }
    }

    /// An install-block failure path consumed ownership before ownership transfer:
    /// `installing → finished`, making any late `onCancel` a no-op on the bridge.
    func markFinished() {
        lock.lock()
        defer { lock.unlock() }
        if state == .installing { state = .finished }
    }
}

extension SMB2Client {

    // MARK: Opt-in connect via transport kind

    /// Connects to `server`/`share` using the external-transport seam.
    ///
    /// Builds the concrete transport for `kind`, wraps it in a `TransportBridge`, installs
    /// the bridge via `smb2_set_transport(AUTO, ext)` before `smb2_connect_share_async`,
    /// and drives the handshake through the no-fd servicing loop rather than `pollUntilComplete`.
    ///
    /// The `tcp`/`automatic` conformer is `TCPTransportApple` (NIOTransportServices); `.quic`
    /// is validated here (design D4/D10) and then constructs `QUICTransportApple`, or throws
    /// `ENOTSUP` below the QUIC availability floor (design D1).
    ///
    /// Endpoint parsing and — for `.quic` — host and connect-timeout validation are hoisted here
    /// (design D4) so they run **before** transport construction and before any network activity,
    /// and so `parseSeamEndpoint` is invoked exactly once. `quicConfiguration` is the immutable
    /// snapshot the manager took under `connectLock` (design D6); it defaults to `nil`, which
    /// means "all `SMBQUICConfiguration` defaults".
    func connect(
        server: String, share: String, user: String,
        transportKind: SMBTransportKind,
        quicConfiguration: SMBQUICConfiguration? = nil
    ) async throws {
        // Parse the endpoint exactly once, with the per-kind default port (design D4).
        let endpoint = try Self.parseSeamEndpoint(
            server, defaultPort: Self.seamDefaultPort(for: transportKind))

        let transport: any SMBTransport
        switch transportKind {
        case .tcp, .automatic:
            transport = TCPTransportApple()
        case .quic:
            // Policy validation runs before any transport object exists or any network activity
            // occurs (design D4), on the endpoint parsed once above — so the numeric-host and
            // port-range rules live in exactly one place shared with `SMBQUICCertificateProbe`.
            try Self.validateQUICEndpoint(host: endpoint.host, port: endpoint.port)
            // Dedicated, finite, always-armed connect deadline (design D10) — independent of
            // `self.timeout`. Validated here, before transport construction and before the
            // availability check; the transport initializer independently normalizes the same
            // value from the configuration, so direct construction cannot bypass the contract.
            _ = try Self.normalizedQUICConnectTimeout(quicConfiguration?.connectTimeout ?? 30)
            if #available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *) {
                transport = try QUICTransportApple(
                    configuration: quicConfiguration ?? SMBQUICConfiguration())
            } else {
                // Below the QUIC availability floor (design D1). Unreachable on CI hosts, which
                // always satisfy the floor; verified by code inspection, scenario marked manual.
                throw POSIXError(.ENOTSUP,
                    description: "SMB over QUIC requires iOS 15 / macOS 12 or later")
            }
        }

        let bridge = TransportBridge(transport: transport)
        try await connectWithBridge(
            server: server, share: share, user: user,
            host: endpoint.host, port: endpoint.port,
            bridge: bridge, selector: Self.seamSelector(for: transportKind))
    }

    // MARK: Seam endpoint parsing (mirrors libsmb2 ext_connect)

    /// Parses a libsmb2 `server` string into `(host, port)`, mirroring `ext_connect`
    /// (`Dependencies/libsmb2/lib/transport-external.c`) byte-for-byte so the eager Swift
    /// connect targets the exact endpoint libsmb2 would have parsed:
    /// - A leading `[` marks an IPv6 literal; the host runs to the matching `]`. A missing `]`
    ///   throws `POSIXError(.EINVAL)`.
    /// - After the optional `]`, the **first** `:` separates host from port; the remainder is the
    ///   port (leading decimal digits, à la `strtol(..., 10)`; `0` when absent/non-numeric).
    /// - No `:` → `defaultPort` (445 for `.tcp`/`.automatic`, 443 for `.quic`; design D4). No DNS
    ///   resolution — the host is handed over verbatim.
    static func parseSeamEndpoint(
        _ server: String, defaultPort: Int
    ) throws -> (host: String, port: Int) {
        if server.first == "[" {
            // IPv6 literal in `[...]` form.
            let afterBracket = server.dropFirst()
            guard let closeIndex = afterBracket.firstIndex(of: "]") else {
                throw POSIXError(.EINVAL,
                    description: "Invalid address: \(server): Missing ']' in IPv6 address")
            }
            let host = String(afterBracket[afterBracket.startIndex..<closeIndex])
            let rest = afterBracket[afterBracket.index(after: closeIndex)...]
            if let colonIndex = rest.firstIndex(of: ":") {
                return (host, parseLeadingPort(rest[rest.index(after: colonIndex)...]))
            }
            return (host, defaultPort)
        }

        // Non-IPv6: split host at the first `:`.
        if let colonIndex = server.firstIndex(of: ":") {
            let host = String(server[server.startIndex..<colonIndex])
            return (host, parseLeadingPort(server[server.index(after: colonIndex)...]))
        }

        return (server, defaultPort)
    }

    // MARK: Per-kind seam endpoint defaults and selector (design D4/D9)

    /// The default port for a transport kind when the server string carries no explicit port:
    /// 445 for `.tcp`/`.automatic`, 443 (UDP) for `.quic` (design D4). Factored so the mapping
    /// is table-testable in one place.
    static func seamDefaultPort(for kind: SMBTransportKind) -> Int {
        switch kind {
        case .tcp, .automatic:
            return 445
        case .quic:
            return 443
        }
    }

    /// The exact `smb2_set_transport` selector for a transport kind (design D9): `.tcp`/
    /// `.automatic` install `SMB2_TRANSPORT_AUTO` (unchanged shipped behavior), `.quic` installs
    /// `SMB2_TRANSPORT_QUIC`. Never `SMB2_TRANSPORT_TCP` — that selects libsmb2's built-in socket
    /// and ignores `ext` (the D1 naming trap). `.automatic` never yields QUIC.
    static func seamSelector(for kind: SMBTransportKind) -> Int32 {
        switch kind {
        case .tcp, .automatic:
            return SMB2_TRANSPORT_AUTO
        case .quic:
            return SMB2_TRANSPORT_QUIC
        }
    }

    // MARK: QUIC endpoint validation (design D4)

    /// Applies the SMB-over-QUIC endpoint policy to an already-parsed `(host, port)` pair:
    /// the host must be a name (never a numeric address, never empty) and the port must be in
    /// 1...65535. Throws `POSIXError(.EINVAL)` otherwise.
    ///
    /// Factored so the `.quic` connect branch and `SMBQUICCertificateProbe` share one classifier
    /// and cannot diverge. Numeric-host rejection is independent of the TLS trust policy —
    /// `.insecureNoVerification` never bypasses it. The port check runs here so an out-of-range
    /// port never constructs a transport or reaches the `NWConnection` driver factory (the driver
    /// independently re-rejects out-of-range ports for directly constructed transports).
    static func validateQUICEndpoint(host: String, port: Int) throws {
        guard !isNumericHost(host) else {
            throw POSIXError(.EINVAL,
                description: "SMB over QUIC requires a hostname, not an IP address")
        }
        guard (1...65535).contains(port) else {
            throw POSIXError(.EINVAL,
                description: "SMB over QUIC: invalid port \(port)")
        }
    }

    /// Parses a `host[:port]` server string with the `.quic` default port (UDP/443) and applies
    /// `validateQUICEndpoint`. The single entry point for callers that have no already-parsed
    /// endpoint (`SMBQUICCertificateProbe`); `connect` parses once itself and calls
    /// `validateQUICEndpoint` directly, preserving its "parsed exactly once" invariant.
    static func validatedQUICEndpoint(_ server: String) throws -> (host: String, port: Int) {
        let endpoint = try parseSeamEndpoint(server, defaultPort: seamDefaultPort(for: .quic))
        try validateQUICEndpoint(host: endpoint.host, port: endpoint.port)
        return endpoint
    }

    /// Parses leading decimal digits from `text`, mirroring C `strtol(text, NULL, 10)`:
    /// returns `0` when no leading digit is present. Overflow-safe by construction: digits stop
    /// accumulating once the value already exceeds 65535 — it is out of the valid port range and
    /// no further digit can bring it back, so an arbitrarily long digit string never traps and
    /// the result stays out-of-range for the caller's `EINVAL` rejection (the accumulated value
    /// is bounded by 655,359). Shared with the TCP path, whose behavior is unchanged for every
    /// in-range port; out-of-range values remain out-of-range (only their exact magnitude is
    /// clamped) and fail downstream identically.
    private static func parseLeadingPort(_ text: Substring) -> Int {
        var port = 0
        var sawDigit = false
        for character in text {
            guard let value = character.wholeNumberValue,
                  character.isASCII, value >= 0, value <= 9
            else { break }
            sawDigit = true
            guard port <= 65535 else { break }
            port = port * 10 + value
        }
        return sawDigit ? port : 0
    }

    /// Maps a transport `connect` failure to a `POSIXError`. Already-`POSIXError` and
    /// `CancellationError` values pass through unchanged (preserving the precise mapping
    /// `TCPTransportApple` produces and cancellation semantics); anything else is wrapped as
    /// `ECONNREFUSED` so callers never see a raw transport error.
    static func mapTransportConnectError(_ error: any Error) -> any Error {
        if error is POSIXError || error is CancellationError {
            return error
        }
        return POSIXError(.ECONNREFUSED, description: "Transport connect failed: \(error)")
    }

    // MARK: Bridge-based connect (internal, testable with MockTransport)

    /// Connects via the provided bridge, driving libsmb2 through the seam servicing loop.
    ///
    /// Exposed as `internal` so tests can inject a `MockTransport`-backed bridge directly,
    /// bypassing the `TCPTransportApple` kind dispatch. Production code calls
    /// `connect(server:share:user:transportKind:quicConfiguration:)`, which resolves the
    /// endpoint (`host`, `port`) and the kind's `selector` and passes them here.
    ///
    /// **Naming trap** (design D1/D9): `selector` is `SMB2_TRANSPORT_AUTO` (`.tcp`/`.automatic`)
    /// or `SMB2_TRANSPORT_QUIC` (`.quic`), never `SMB2_TRANSPORT_TCP` — `TCP == 0` selects
    /// libsmb2's built-in socket and ignores `ext`. After `smb2_set_transport(selector, ext)`,
    /// `smb2_get_fd(context)` returns -1 — no native socket fd exists.
    ///
    /// **Cancellation-safe bridge-ownership handoff** (design D12): a single outer
    /// `withTaskCancellationHandler` covers the whole interval — from before the eager
    /// `bridge.connect` through seam installation. A lock-protected `BridgeOwnershipHandoff`
    /// records exactly one bridge owner at every instant, so the bridge closes exactly once on
    /// every path and no cancellation interleaving leaves a connected-but-unowned bridge, an
    /// unmanaged retain, a continuation, or a registered libsmb2 operation.
    func connectWithBridge(
        server: String, share: String, user: String,
        host: String, port: Int,
        bridge: TransportBridge,
        selector: Int32
    ) async throws {
        // `cb`/`cbId` are Sendable (CBData is @unchecked Sendable, ObjectIdentifier is Sendable)
        // and safe to capture across the isolation boundary. `cbPtr` is built INSIDE the install
        // block (a local, not a capture) to avoid the Swift 6 @Sendable-capture warning.
        let cb = CBData()
        let cbId = ObjectIdentifier(cb)
        let handoff = BridgeOwnershipHandoff()

        try await withTaskCancellationHandler {
            // Cancellation before start: nothing is connected yet, so nothing to close.
            try Task.checkCancellation()

            // Eager connect (fix-seam-connect-ordering): establish the transport BEFORE libsmb2
            // begins the handshake. `ext_connect` fires NEGOTIATE synchronously on a `>= 0`
            // return, so the channel must be live first or the first outbound send fails with
            // ENOTCONN. Connecting is also what hands the bridge's inbound receiver to the
            // transport. This `await` runs on the caller's task — never on `eventLoopQueue`.
            let eagerFailure: (any Error)?
            do {
                try await bridge.connect(host: host, port: port)
                eagerFailure = nil
            } catch {
                eagerFailure = error
            }

            // Eager-completion reconciliation (design D12, rows A–D + race E): ONE lock-protected
            // transition combines the handoff state (did cancellation win?) with the connect
            // result and assigns the single close/error duty.
            switch handoff.reconcile(connectFailed: eagerFailure != nil) {
            case .proceed:
                break  // row A: eagerConnecting → localOwned; proceed toward installation.
            case .cancellationWon:
                // rows B/C: cancellation committed first (success-after-cancel or a
                // cancellation-shaped failure alike). Close the still-local bridge exactly once
                // and normalize to CancellationError — never a raw ECANCELED, never a libsmb2 call.
                bridge.close()
                throw CancellationError()
            case .eagerFailed:
                // row D: ordinary eager failure, cancellation did not win. Close exactly once and
                // rethrow the mapped original transport error (never CancellationError).
                bridge.close()
                throw Self.mapTransportConnectError(eagerFailure!)
            }

            // Installation, serialized on `eventLoopQueue`.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.eventLoopQueue.async { [self] in
                    // FIRST step, before ANY resource is created: claim installation. A failed
                    // claim means cancellation already won at `localOwned` (onCancel closed the
                    // bridge). Create nothing — no `cbPtr`, no `Unmanaged.passRetained(cb)`, no
                    // `makeExternalTransport()`, no libsmb2 call — and resume CancellationError.
                    guard handoff.claimInstalling() else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    // Only after a successful claim: construct the opaque pointer locally to
                    // avoid capturing a non-Sendable UnsafeMutableRawPointer across the boundary.
                    let cbPtr = Unmanaged.passRetained(cb).toOpaque()

                    guard let context = self.context else {
                        // Context gone. makeExternalTransport() has NOT run, so no ext.userdata
                        // retain exists — release only cbPtr and close the eagerly-connected
                        // bridge (its C close trampoline is not wired yet).
                        bridge.close()
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        handoff.markFinished()
                        continuation.resume(throwing: POSIXError(.ENOTCONN))
                        return
                    }

                    // Install the bridge as the external transport with the kind's exact selector
                    // (design D9). NAMING TRAP: AUTO/QUIC route `ext`; TCP (== 0) would ignore it.
                    var ext = bridge.makeExternalTransport()
                    let transportResult = smb2_set_transport(context, selector, &ext)
                    guard transportResult == 0 else {
                        // smb2_set_transport failed: libsmb2 did NOT install our ext struct, so
                        // the C close trampoline will never fire. Balance the passRetained that
                        // makeExternalTransport() performed, close the transport, release cbPtr.
                        // bridge.close() touches only the transport/pumps — no double-release.
                        bridge.close()
                        Unmanaged<TransportBridge>.fromOpaque(ext.userdata!).release()
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        handoff.markFinished()
                        continuation.resume(throwing: POSIXError(.EINVAL,
                            description: "smb2_set_transport failed: \(transportResult)"))
                        return
                    }
                    // Assert the naming trap: after AUTO/QUIC install, fd must be -1.
                    assert(smb2_get_fd(context) == -1,
                        "seam transport must not own a native socket fd")

                    // Propagate our Swift-level timeout into libsmb2 so per-PDU deadlines
                    // are set. This enables smb2_get_timeout to return a live deadline and
                    // scheduleSeamTimeout to drive smb2_service_timeout on the event loop.
                    // Minimum 1 s (libsmb2 takes integer seconds; sub-second Swift timeouts
                    // are covered by the asyncAfter below).
                    if self.timeout > 0 {
                        let libTimeoutSecs = max(1, Int32(self.timeout.rounded(.up)))
                        smb2_set_timeout(context, libTimeoutSecs)
                    }

                    // Wire up the inbound-ready signal: bridge → (debounce) → eventLoopQueue →
                    // service. The debounce coalesces a burst of per-chunk signals into a single
                    // service dispatch (see consumeInboundReadySignal/beginServicePass).
                    bridge.setInboundReadyHandler { [weak self] in
                        guard let self, self.consumeInboundReadySignal() else { return }
                        self.eventLoopQueue.async { [weak self] in
                            guard let self else { return }
                            // Clear the flag BEFORE draining so a chunk arriving mid-drain re-arms.
                            self.beginServicePass()
                            self.serviceContextForSeam()
                        }
                    }
                    self.transportBridge = bridge
                    // Ownership now belongs to transportBridge/teardownSeam(); a late onCancel
                    // routes through the installed teardown (design D12).
                    handoff.markInstalled()

                    // Register the connect operation.
                    let connectResult = smb2_connect_share_async(
                        context, server, share, user,
                        SMB2Client.generic_handler, cbPtr
                    )
                    if connectResult < 0 {
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        let errCode = Int32(-connectResult)
                        let errDesc = self.error.map { "Error code \(errCode): \($0)" }
                        // Tear down the seam state: transportBridge was just set and the
                        // bridge registered an inbound-ready handler, but the operation
                        // never reached the pending-operations table.
                        self.teardownSeam()
                        continuation.resume(
                            throwing: POSIXError(.init(errCode), description: errDesc))
                        return
                    }

                    cb.continuation = continuation

                    // Race: onCancel may have fired before the continuation was stored.
                    if cb.isAbandoned {
                        cb.continuation = nil
                        // Do NOT release here: smb2_connect_share_async has already queued
                        // NEGOTIATE, so libsmb2 owns cbPtr and will fire generic_handler exactly
                        // once — via its internal connect callback chain during
                        // smb2_destroy_context's teardown sweep — which performs the single
                        // balancing takeRetainedValue(). Releasing now would double-balance →
                        // use-after-free (fix-cbdata-cancel-race-uaf).
                        self.teardownSeam()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    // `weak cb`: `cleanup` is stored ON `cb`, so a strong capture would be a
                    // `cb -> cleanup -> cb` cycle that outlives a timed-out/cancelled connect until
                    // the context is destroyed. `generic_handler` holds `cbdata` strongly while
                    // invoking `cleanup`, so the weak reference is always live here.
                    cb.cleanup = { [weak self, weak cb] in
                        self?.pendingOperations.removeValue(forKey: cbId)
                        // Mark seam-connected only on success (result == NTStatus.success == 0).
                        if cb?.result == Int32(NTStatus.success.rawValue) {
                            self?.seamConnected = true
                        }
                    }
                    self.pendingOperations[cbId] = cb

                    // Start the outbound pump now so bytes can flow immediately. The ordering
                    // here is load-bearing (design D2): the pump is started *after*
                    // `setInboundReadyHandler` above, so no outbound byte (NEGOTIATE) can leave
                    // before the inbound-ready handler is registered and the server can have
                    // nothing to answer. That keeps the pre-registration delivery window to
                    // unsolicited events only — and those are covered by the bridge's
                    // signal-on-registration. Do not move this call above the registration.
                    bridge.startOutboundPump()

                    // Flush any outbound PDUs libsmb2 queued during smb2_set_transport
                    // or smb2_connect_share_async (e.g. NEGOTIATE).
                    self.flushOutboundForSeam(context: context)

                    // Arm timer-driven servicing (per-request timeouts, QUIC timers later).
                    self.scheduleSeamTimeout()

                    // Per-operation timeout (distinct from smb2_get_timeout timers).
                    if self.timeout > 0 {
                        self.eventLoopQueue.asyncAfter(
                            deadline: .now() + self.timeout
                        ) { [weak self, weak cb] in
                            guard let cb, !cb.isAbandoned else { return }
                            cb.isAbandoned = true
                            self?.pendingOperations.removeValue(forKey: cbId)
                            self?.teardownSeam()
                            if let cont = cb.continuation {
                                cb.continuation = nil
                                cont.resume(throwing: POSIXError(.ETIMEDOUT))
                            }
                        }
                    }
                }
            }
        } onCancel: {
            // Ownership-aware cancellation (design D12): the handoff assigns the single duty.
            switch handoff.cancel() {
            case .noClose:
                // eagerConnecting → cancelled: the eager-completion reconciliation performs the
                // single bridge.close(); terminal states have nothing to do.
                break
            case .closeLocalBridge:
                // localOwned → cancelled: the connected bridge is locally owned and not yet
                // installed; close it exactly once here.
                bridge.close()
            case .installedTeardown:
                // installing/installed: route through the installed-ownership teardown. Queue
                // serialization guarantees the install block completes first, so teardownSeam()
                // closes the installed seam exactly once and the continuation resumes once.
                self.eventLoopQueue.async { [self] in
                    guard !cb.isAbandoned else { return }
                    cb.isAbandoned = true
                    self.pendingOperations.removeValue(forKey: cbId)
                    self.teardownSeam()
                    if let cont = cb.continuation {
                        cb.continuation = nil
                        cont.resume(throwing: CancellationError())
                    }
                }
            }
        }

        // After continuation.resume() from generic_handler: check the SMB2 status.
        if let cbError = cb.error { throw cbError }
        try POSIXError.throwIfError(cb.result, description: error)
    }

    // MARK: Inbound-ready debounce

    /// Debounce decision for an inbound-ready signal. Returns `true` for the first signal of a
    /// burst (the first after the previous pass began) and `false` while a pass is already
    /// pending, so a flurry of per-chunk signals collapses into a single `serviceContextForSeam`
    /// dispatch. Thread-safe; called off `eventLoopQueue` from the bridge's inbound-ready callback.
    func consumeInboundReadySignal() -> Bool {
        serviceFlagLock.withLock {
            if servicePending { return false }
            servicePending = true
            // The `false → true` flip is the one place a dispatch interval opens; emitting under
            // the lock keeps begin/end strictly ordered with the flag they bracket.
            InboundSignposts.dispatchBegin(for: self)
            return true
        }
    }

    /// Clears the debounce flag at the START of a queued service pass — BEFORE
    /// `serviceContextForSeam` drains the inbound buffer. This ordering guarantees no lost
    /// wakeup: a chunk appended after the reset (even mid-drain) re-arms a fresh pass via
    /// `consumeInboundReadySignal()`. Runs on `eventLoopQueue`.
    @discardableResult
    func beginServicePass() -> Bool {
        clearInboundReadySignal()
    }

    /// Clears the debounce flag and reports whether a signal was actually armed, closing the
    /// `ServiceDispatch` interval exactly in that case. The single clearing path shared by
    /// `beginServicePass()` and `teardownSeam()`, so an interval can never be ended twice.
    /// Thread-safe.
    private func clearInboundReadySignal() -> Bool {
        serviceFlagLock.withLock {
            let wasArmed = servicePending
            servicePending = false
            if wasArmed { InboundSignposts.dispatchEnd(for: self) }
            return wasArmed
        }
    }

    // MARK: No-fd servicing loop

    /// Services libsmb2 for the seam path: calls `smb2_service` with the events indicated by
    /// `smb2_which_events`, then flushes any pending outbound PDUs, then reschedules the timer.
    ///
    /// Must run on `eventLoopQueue`. Called exclusively from the bridge's inbound-ready callback
    /// (installed by `bridge.setInboundReadyHandler` in `connectWithBridge`). The timer
    /// (`scheduleSeamTimeout`) and outbound flush (`flushOutboundForSeam`) call `smb2_service`
    /// and `smb2_service_timeout` directly and do NOT route through this function.
    func serviceContextForSeam() {
        guard let context else { return }

        InboundSignposts.passBegin(for: self)
        // `teardownSeam()` nils `transportBridge` on this same queue, so reading it here covers
        // both failure paths (this function's own, and the one inside `flushOutboundForSeam`).
        defer { InboundSignposts.passEnd(for: self, terminal: transportBridge == nil) }

        // Use smb2_which_events to determine what libsmb2 currently needs, then OR in POLLIN
        // because this function is always triggered by inbound-byte readiness.
        let revents = smb2_which_events(context) | Int32(POLLIN)
        let serviceResult = smb2_service(context, revents)
        if serviceResult < 0 {
            let errorMsg = error
            teardownSeam()
            failPendingAndDestroyContext(with: POSIXError(.ECONNRESET, description: errorMsg))
            return
        }

        // Flush any outbound PDUs that libsmb2 generated during service.
        flushOutboundForSeam(context: context)

        // Reschedule timer to match the new libsmb2 deadline.
        scheduleSeamTimeout()
    }

    /// Calls `smb2_service(POLLOUT)` while libsmb2 reports pending output.
    ///
    /// Each POLLOUT service invokes the C `send` trampoline, which enqueues bytes in the
    /// bridge's outbound FIFO. The outbound pump Task drains the FIFO via `transport.send`.
    /// The loop is capped at 32 passes to avoid starving other event-loop work. If POLLOUT
    /// is still set after the cap, a follow-up flush is re-armed asynchronously so pending
    /// outbound PDUs are not silently stalled.
    /// Must run on `eventLoopQueue`.
    func flushOutboundForSeam(context: UnsafeMutablePointer<smb2_context>) {
        var iterations = 0
        while (smb2_which_events(context) & Int32(POLLOUT)) != 0, iterations < 32 {
            let result = smb2_service(context, Int32(POLLOUT))
            if result < 0 {
                let errorMsg = error
                teardownSeam()
                failPendingAndDestroyContext(with: POSIXError(.ECONNRESET, description: errorMsg))
                return
            }
            iterations += 1
        }
        // If POLLOUT is still asserted after 32 passes, re-arm a flush on the next
        // event-loop turn so large outbound bursts don't stall silently.
        if iterations == 32, (smb2_which_events(context) & Int32(POLLOUT)) != 0 {
            eventLoopQueue.async { [weak self] in
                guard let self, let ctx = self.context else { return }
                self.flushOutboundForSeam(context: ctx)
            }
        }
    }

    /// Schedules `smb2_service_timeout` at the next deadline reported by `smb2_get_timeout`.
    ///
    /// `smb2_get_timeout` returns 1 when a deadline is set and fills `tv` with the remaining
    /// time until that deadline (relative duration). Returns 0 for "no timer pending".
    /// The timer is rescheduled after every service pass so libsmb2's deadline tracking stays
    /// accurate. Must run on `eventLoopQueue`.
    func scheduleSeamTimeout() {
        // Only the seam drives this timer; bail out once the seam is torn down so a
        // rescheduling chain cannot outlive `transportBridge`.
        guard let context, transportBridge != nil else { return }
        // Cancel any previously scheduled timer; libsmb2's deadline may have changed.
        pendingTimeoutItem?.cancel()
        pendingTimeoutItem = nil

        var tv = timeval()
        guard smb2_get_timeout(context, &tv) == 1 else { return }  // 0 = no timer pending
        let remaining = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
        // Due now or already past — defer with a minimum 1 ms floor so the queue does not
        // busy-spin if `smb2_get_timeout` keeps reporting {0,0} (persistent timeout churn
        // under heavy load); a 1 ms minimum lets the Swift pool and other GCD work run.
        let delay = max(remaining, 0.001)

        let item = DispatchWorkItem { [weak self] in
            guard let self, let context = self.context else { return }
            _ = smb2_service_timeout(context)
            self.flushOutboundForSeam(context: context)
            self.scheduleSeamTimeout()
        }
        // Track every scheduled item (including the floor path) in `pendingTimeoutItem` so
        // `teardownSeam()` cancels it and repeated calls naturally deduplicate.
        pendingTimeoutItem = item
        eventLoopQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Tears down the seam: cancels the timer, clears the bridge reference, resets
    /// `seamConnected`. Must run on `eventLoopQueue`.
    ///
    /// Calling `bridge.close()` cancels the outbound pump Task and calls `transport.close()` in
    /// a background Task (see `TransportBridge.close()`). Idempotent.
    func teardownSeam() {
        pendingTimeoutItem?.cancel()
        pendingTimeoutItem = nil
        seamConnected = false
        // Reset the inbound-ready debounce so a stuck `servicePending` can never outlive the seam.
        // Without this, a client reused across a reconnect would coalesce every future signal
        // against a stale `true` and silently never schedule a service pass (connect would hang).
        _ = clearInboundReadySignal()
        if let bridge = transportBridge {
            transportBridge = nil
            bridge.close()
        }
    }
}

#endif // canImport(Network)

extension SMB2Client {
    struct NegotiateSigning: OptionSet, Sendable, CustomStringConvertible {
        var rawValue: UInt16

        var description: String {
            var result: [String] = []
            if contains(.enabled) { result.append("Enabled") }
            if contains(.required) { result.append("Required") }
            return result.joined(separator: ", ")
        }

        static let enabled = NegotiateSigning(rawValue: SMB2_NEGOTIATE_SIGNING_ENABLED)
        static let required = NegotiateSigning(rawValue: SMB2_NEGOTIATE_SIGNING_REQUIRED)
    }

    typealias Version = smb2_negotiate_version
    typealias Security = smb2_sec
}

extension SMB2.smb2_negotiate_version: Swift.Hashable, Swift.CustomStringConvertible {
    static let any = SMB2_VERSION_ANY
    static let v2 = SMB2_VERSION_ANY2
    static let v3 = SMB2_VERSION_ANY3
    static let v2_02 = SMB2_VERSION_0202
    static let v2_10 = SMB2_VERSION_0210
    static let v3_00 = SMB2_VERSION_0300
    static let v3_02 = SMB2_VERSION_0302
    static let v3_11 = SMB2_VERSION_0311

    public var description: String {
        switch self {
        case .any: return "Any"
        case .v2: return "2.0"
        case .v3: return "3.0"
        case .v2_02: return "2.02"
        case .v2_10: return "2.10"
        case .v3_00: return "3.00"
        case .v3_02: return "3.02"
        case .v3_11: return "3.11"
        default: return "Unknown"
        }
    }

    static func ==(lhs: smb2_negotiate_version, rhs: smb2_negotiate_version) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

extension SMB2.smb2_sec: Swift.Hashable, Swift.CustomStringConvertible {
    static let undefined = SMB2_SEC_UNDEFINED
    static let ntlmSsp = SMB2_SEC_NTLMSSP
    static let kerberos5 = SMB2_SEC_KRB5

    public var description: String {
        switch self {
        case .undefined: return "Undefined"
        case .ntlmSsp: return "NTLM SSP"
        case .kerberos5: return "Kerberos5"
        default: return "Unknown"
        }
    }

    static func ==(lhs: smb2_sec, rhs: smb2_sec) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

struct SMB2Share {
    let name: String
    let props: ShareProperties
    let comment: String
}

struct ShareProperties: RawRepresentable {
    enum ShareType: UInt32 {
        case diskTree
        case printQueue
        case device
        case ipc
        case unknown = 0xFFFF_FFFF
    }

    let rawValue: UInt32

    var type: ShareType {
        ShareType(rawValue: rawValue & 0x0fff_ffff) ?? .unknown
    }

    var isTemporary: Bool {
        rawValue & UInt32(bitPattern: SHARE_TYPE_TEMPORARY) != 0
    }

    var isHidden: Bool {
        rawValue & SHARE_TYPE_HIDDEN != 0
    }
}

struct NTStatus: LocalizedError, Hashable, Sendable {
    enum Severity: UInt32, Hashable, Sendable, CustomStringConvertible {
        case success
        case info
        case warning
        case error

        var description: String {
            switch self {
            case .success: return "Success"
            case .info: return "Info"
            case .warning: return "Warning"
            case .error: return "Error"
            }
        }

        init(status: NTStatus) {
            self = switch status.rawValue & SMB2_STATUS_SEVERITY_MASK {
            case UInt32(bitPattern: SMB2_STATUS_SEVERITY_SUCCESS):
                .success
            case UInt32(bitPattern: SMB2_STATUS_SEVERITY_INFO):
                .info
            case SMB2_STATUS_SEVERITY_WARNING:
                .warning
            case SMB2_STATUS_SEVERITY_ERROR:
                .error
            default:
                .success
            }
        }
    }

    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(rawValue: Int32) {
        self.rawValue = .init(bitPattern: rawValue)
    }

    var errorDescription: String? {
        nterror_to_str(rawValue).map(String.init(cString:))
    }

    var posixErrorCode: POSIXErrorCode {
        .init(nterror_to_errno(rawValue))
    }

    var severity: Severity {
        .init(status: self)
    }

    static let success = Self(rawValue: SMB2_STATUS_SUCCESS)
}
