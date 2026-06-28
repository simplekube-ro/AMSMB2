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

    internal init(timeout: TimeInterval) throws {
        let ctx = try smb2_init_context().unwrap()
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
        failAllPendingOperations(with: POSIXError(.ECANCELED))
        if let ctx = context {
            if smb2_get_fd(ctx) >= 0 {
                // Best-effort graceful disconnect: queue the FIN PDU and flush it once.
                smb2_disconnect_share_async(ctx, SMB2Client.generic_handler_noop, nil)
                smb2_service(ctx, Int32(POLLOUT))
            }
            smb2_destroy_context(ctx)
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
            smb2_destroy_context(context)
            self.context = nil
            socketMonitor?.cancel()
            socketMonitor = nil
            failAllPendingOperations(with: POSIXError(.ECONNRESET, description: errorMsg))
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

    #if canImport(Network)
    /// Number of seam operations currently registered in the pending table, read on the
    /// serialized event-loop queue. Used by the seam acceptance tests to assert that a
    /// cancelled or timed-out operation is removed (no leaked continuation / pending op),
    /// satisfying the connect-ordering spec's teardown requirements.
    var pendingSeamOperationCount: Int {
        syncOnEventLoop { pendingOperations.count }
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
                self.failAllPendingOperations(with: POSIXError(.ENOTCONN))
                continuation.resume()
                #else
                guard let context = self.context, smb2_get_fd(context) >= 0 else {
                    self.stopSocketMonitoring()
                    self.failAllPendingOperations(with: POSIXError(.ENOTCONN))
                    continuation.resume()
                    return
                }
                smb2_disconnect_share_async(context, SMB2Client.generic_handler_noop, nil)
                smb2_service(context, Int32(POLLOUT))
                self.stopSocketMonitoring()
                self.failAllPendingOperations(with: POSIXError(.ENOTCONN))
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
                smb2_destroy_context(context)
                self.context = nil
                throw POSIXError(.ECONNRESET, description: error)
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
            guard !cbdata.isAbandoned else { return }
            cbdata.isAbandoned = true
            if NTStatus(rawValue: status) != .success {
                cbdata.result = status
            }
            cbdata.dataHandler?(command_data)
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
        cb.dataHandler = { ptr in
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
                            Unmanaged<CBData>.fromOpaque(cbPtr).release()
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
                            self.eventLoopQueue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                                guard !cb.isAbandoned else { return }
                                cb.isAbandoned = true
                                self?.pendingOperations.removeValue(forKey: cbId)
                                if let cont = cb.continuation {
                                    cb.continuation = nil
                                    cont.resume(throwing: POSIXError(.ETIMEDOUT))
                                }
                            }
                        }
                    } catch {
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
        cb.dataHandler = { ptr in
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
                            Unmanaged<CBData>.fromOpaque(cbPtr).release()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        cb.cleanup = { [weak self] in
                            self?.pendingOperations.removeValue(forKey: cbId)
                        }
                        self.pendingOperations[cbId] = cb
                        self.activateServicingAfterOperation(context: context)

                        if self.timeout > 0 {
                            self.eventLoopQueue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                                guard !cb.isAbandoned else { return }
                                cb.isAbandoned = true
                                self?.pendingOperations.removeValue(forKey: cbId)
                                if let cont = cb.continuation {
                                    cb.continuation = nil
                                    cont.resume(throwing: POSIXError(.ETIMEDOUT))
                                }
                            }
                        }
                } catch {
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

extension SMB2Client {

    // MARK: Opt-in connect via transport kind

    /// Connects to `server`/`share` using the external-transport seam.
    ///
    /// Builds the concrete transport for `kind`, wraps it in a `TransportBridge`, installs
    /// the bridge via `smb2_set_transport(AUTO, ext)` before `smb2_connect_share_async`,
    /// and drives the handshake through the no-fd servicing loop rather than `pollUntilComplete`.
    ///
    /// The `tcp`/`automatic` conformer is `TCPTransportApple` (NIOTransportServices).
    func connect(
        server: String, share: String, user: String,
        transportKind: SMBTransportKind
    ) async throws {
        let transport: any SMBTransport
        switch transportKind {
        case .tcp, .automatic:
            transport = TCPTransportApple()
        case .quic:
            throw POSIXError(.ENOTSUP, description: "QUIC transport not yet implemented")
        }
        let bridge = TransportBridge(transport: transport)
        try await connectWithBridge(server: server, share: share, user: user, bridge: bridge)
    }

    // MARK: Seam endpoint parsing (mirrors libsmb2 ext_connect)

    /// Parses a libsmb2 `server` string into `(host, port)`, mirroring `ext_connect`
    /// (`Dependencies/libsmb2/lib/transport-external.c`) byte-for-byte so the eager Swift
    /// connect targets the exact endpoint libsmb2 would have parsed:
    /// - A leading `[` marks an IPv6 literal; the host runs to the matching `]`. A missing `]`
    ///   throws `POSIXError(.EINVAL)`.
    /// - After the optional `]`, the **first** `:` separates host from port; the remainder is the
    ///   port (leading decimal digits, à la `strtol(..., 10)`; `0` when absent/non-numeric).
    /// - No `:` → default port `445`. No DNS resolution — the host is handed over verbatim.
    static func parseSeamEndpoint(_ server: String) throws -> (host: String, port: Int) {
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
            return (host, 445)
        }

        // Non-IPv6: split host at the first `:`.
        if let colonIndex = server.firstIndex(of: ":") {
            let host = String(server[server.startIndex..<colonIndex])
            return (host, parseLeadingPort(server[server.index(after: colonIndex)...]))
        }

        return (server, 445)
    }

    /// Parses leading decimal digits from `text`, mirroring C `strtol(text, NULL, 10)`:
    /// returns `0` when no leading digit is present.
    private static func parseLeadingPort(_ text: Substring) -> Int {
        var port = 0
        var sawDigit = false
        for character in text {
            guard let value = character.wholeNumberValue,
                  character.isASCII, value >= 0, value <= 9
            else { break }
            port = port * 10 + value
            sawDigit = true
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
    /// `connect(server:share:user:transportKind:)` instead.
    ///
    /// **Naming trap** (design D1): `SMB2_TRANSPORT_AUTO` is used, not `SMB2_TRANSPORT_TCP`.
    /// `TCP == 0` selects libsmb2's built-in socket (and ignores `ext`); `AUTO == 2` routes
    /// our external bridge through the seam. After `smb2_set_transport(AUTO, ext)`, calling
    /// `smb2_get_fd(context)` returns -1 — no native socket fd exists.
    func connectWithBridge(
        server: String, share: String, user: String,
        bridge: TransportBridge
    ) async throws {
        try Task.checkCancellation()

        // Eager connect (fix-seam-connect-ordering): establish the transport BEFORE libsmb2
        // begins the handshake. `ext_connect` fires NEGOTIATE synchronously on a `>= 0` return,
        // so the channel must be live first or the first send()/receive() fails with ENOTCONN.
        // This `await` runs on the caller's task — never on `eventLoopQueue` — so it blocks no
        // serialized work. A connect failure surfaces here as a thrown `POSIXError`, with no
        // libsmb2 operation registered and the bridge/transport never installed.
        let endpoint = try Self.parseSeamEndpoint(server)
        do {
            try await bridge.connect(host: endpoint.host, port: endpoint.port)
        } catch {
            throw Self.mapTransportConnectError(error)
        }

        // `cbPtr` (UnsafeMutableRawPointer) is constructed INSIDE the eventLoopQueue.async
        // block — a local variable rather than a captured binding — so it does not trigger the
        // Swift 6 @SendableClosureCaptures warning that affects the legacy async_await functions.
        // `cb` and `cbId` are Sendable (CBData is @unchecked Sendable, ObjectIdentifier is Sendable)
        // and are safe to capture across the isolation boundary.
        let cb = CBData()
        let cbId = ObjectIdentifier(cb)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.eventLoopQueue.async { [self] in
                    // Construct the opaque pointer locally to avoid capturing a non-Sendable
                    // UnsafeMutableRawPointer across the @Sendable closure boundary.
                    let cbPtr = Unmanaged.passRetained(cb).toOpaque()

                    guard let context = self.context else {
                        // The transport was already connected eagerly above; close it so the
                        // live channel does not leak (the C close trampoline is not wired yet —
                        // makeExternalTransport() has not run).
                        bridge.close()
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        continuation.resume(throwing: POSIXError(.ENOTCONN))
                        return
                    }

                    // Install the bridge as the external transport.
                    // NAMING TRAP: use AUTO (== 2), not TCP (== 0).
                    // TCP selects libsmb2's built-in socket and ignores `ext`.
                    var ext = bridge.makeExternalTransport()
                    let transportResult = smb2_set_transport(
                        context, SMB2_TRANSPORT_AUTO, &ext
                    )
                    guard transportResult == 0 else {
                        // smb2_set_transport failed: libsmb2 did NOT install our ext struct,
                        // so the C close trampoline will never fire. Manually balance the
                        // passRetained that makeExternalTransport() performed on the bridge,
                        // and close the eagerly-connected transport so the channel does not leak.
                        // bridge.close() touches only the transport/pumps — no double-release of
                        // the Unmanaged below.
                        bridge.close()
                        Unmanaged<TransportBridge>.fromOpaque(ext.userdata!).release()
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        continuation.resume(throwing: POSIXError(.EINVAL,
                            description: "smb2_set_transport failed: \(transportResult)"))
                        return
                    }
                    // Assert the naming trap: after AUTO install, fd must be -1.
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
                        Unmanaged<CBData>.fromOpaque(cbPtr).release()
                        self.teardownSeam()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    cb.cleanup = { [weak self] in
                        self?.pendingOperations.removeValue(forKey: cbId)
                        // Mark seam-connected only on success (result == NTStatus.success == 0).
                        if cb.result == Int32(NTStatus.success.rawValue) {
                            self?.seamConnected = true
                        }
                    }
                    self.pendingOperations[cbId] = cb

                    // Start pumps now so bytes can flow immediately.
                    bridge.startPumps()

                    // Flush any outbound PDUs libsmb2 queued during smb2_set_transport
                    // or smb2_connect_share_async (e.g. NEGOTIATE).
                    self.flushOutboundForSeam(context: context)

                    // Arm timer-driven servicing (per-request timeouts, QUIC timers later).
                    self.scheduleSeamTimeout()

                    // Per-operation timeout (distinct from smb2_get_timeout timers).
                    if self.timeout > 0 {
                        self.eventLoopQueue.asyncAfter(
                            deadline: .now() + self.timeout
                        ) { [weak self] in
                            guard !cb.isAbandoned else { return }
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
            return true
        }
    }

    /// Clears the debounce flag at the START of a queued service pass — BEFORE
    /// `serviceContextForSeam` drains the inbound buffer. This ordering guarantees no lost
    /// wakeup: a chunk appended after the reset (even mid-drain) re-arms a fresh pass via
    /// `consumeInboundReadySignal()`. Runs on `eventLoopQueue`.
    func beginServicePass() {
        serviceFlagLock.withLock { servicePending = false }
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

        // Use smb2_which_events to determine what libsmb2 currently needs, then OR in POLLIN
        // because this function is always triggered by inbound-byte readiness.
        let revents = smb2_which_events(context) | Int32(POLLIN)
        let serviceResult = smb2_service(context, revents)
        if serviceResult < 0 {
            let errorMsg = error
            smb2_destroy_context(context)
            self.context = nil
            teardownSeam()
            failAllPendingOperations(with: POSIXError(.ECONNRESET, description: errorMsg))
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
                smb2_destroy_context(context)
                self.context = nil
                teardownSeam()
                failAllPendingOperations(with: POSIXError(.ECONNRESET, description: errorMsg))
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
    /// Calling `bridge.close()` cancels the pump Tasks and calls `transport.close()` in a
    /// background Task (see `TransportBridge.close()`). Idempotent.
    func teardownSeam() {
        pendingTimeoutItem?.cancel()
        pendingTimeoutItem = nil
        seamConnected = false
        // Reset the inbound-ready debounce so a stuck `servicePending` can never outlive the seam.
        // Without this, a client reused across a reconnect would coalesce every future signal
        // against a stale `true` and silently never schedule a service pass (connect would hang).
        serviceFlagLock.withLock { servicePending = false }
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
