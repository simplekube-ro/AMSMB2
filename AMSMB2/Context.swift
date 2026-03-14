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

/// Reusable buffer pool that eliminates per-read `Data(repeating: 0, count:)` allocation
/// and the extra `Data(buffer.prefix(...))` copy. Buffers are pre-allocated and recycled.
final class BufferPool: @unchecked Sendable {
    private var pool: [Data] = []
    private let maxPoolSize: Int

    init(maxPoolSize: Int = 8) {
        self.maxPoolSize = maxPoolSize
    }

    /// Returns a buffer of at least `minimumSize` bytes. No zero-fill is performed.
    func checkout(minimumSize: Int) -> Data {
        if let index = pool.lastIndex(where: { $0.count >= minimumSize }) {
            return pool.remove(at: index)
        }
        if let index = pool.indices.last {
            var buffer = pool.remove(at: index)
            buffer.count = minimumSize
            return buffer
        }
        return Data(count: minimumSize)
    }

    /// Returns a buffer to the pool for reuse. Buffers beyond maxPoolSize are released.
    func checkin(_ buffer: Data) {
        guard pool.count < maxPoolSize else { return }
        pool.append(buffer)
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
    private let eventLoopQueue: DispatchQueue

    /// DispatchSource-based socket monitor, created after connect.
    private var socketMonitor: SocketMonitor?

    /// Tracks all pending operations for error broadcast on connection drop.
    private var pendingOperations: [ObjectIdentifier: CBData] = [:]

    /// Reusable buffer pool for read operations. Eliminates per-read allocation overhead.
    let bufferPool = BufferPool()

    var timeout: TimeInterval

    internal init(timeout: TimeInterval) throws {
        let ctx = try smb2_init_context().unwrap()
        self.context = ctx
        self.timeout = timeout
        self.eventLoopQueue = DispatchQueue(
            label: "smb2_eventloop_\(UInt(bitPattern: ctx))"
        )
    }

    deinit {
        guard context != nil else { return }
        // Cancel socket monitoring first
        socketMonitor?.cancel()
        socketMonitor = nil
        // Fail all pending operations
        failAllPendingOperations(with: POSIXError(.ECANCELED))
        // Disconnect and destroy
        if isConnected {
            // Fire-and-forget disconnect on the event loop
            let ctx = context!
            smb2_disconnect_share_async(ctx, SMB2Client.generic_handler_noop, nil)
            // Service once to flush
            smb2_service(ctx, 0)
        }
        if let ctx = context {
            smb2_destroy_context(ctx)
            context = nil
        }
    }

    /// Raw context pointer for internal module use.
    /// Only safe to access from the event loop queue or from callbacks during smb2_service.
    var rawContext: UnsafeMutablePointer<smb2_context>? { context }

    /// Executes a closure on the event loop queue with the context.
    /// Used for simple synchronous property access — not for async I/O operations.
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

    /// Fire-and-forget: dispatches a closure to the event loop queue without waiting.
    /// Used for cleanup operations (close, closedir) in deinit where we can't wait.
    func fireAndForget(_ handler: @Sendable @escaping (UnsafeMutablePointer<smb2_context>) -> Void) {
        guard let ctx = context else { return }
        let ctxPtr = UInt(bitPattern: ctx)
        eventLoopQueue.async {
            let ctx = UnsafeMutablePointer<smb2_context>(bitPattern: ctxPtr)!
            handler(ctx)
        }
    }

    public var debugDescription: String {
        String(reflecting: self)
    }

    public var customMirror: Mirror {
        var c: [(label: String?, value: Any)] = []
        if context != nil {
            c.append((label: "server", value: server!))
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

// MARK: - Socket Monitor (DispatchSource-based)

extension SMB2Client {
    /// Monitors a socket file descriptor using DispatchSource for efficient,
    /// non-blocking I/O. Replaces the old poll() loop.
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
            readSource.setEventHandler { [weak self] in
                self?.onEvent()
            }
            readSource.resume()
        }

        /// Activates the write source when libsmb2 has data to send.
        func activateWriteSourceIfNeeded(context: UnsafeMutablePointer<smb2_context>) {
            let events = smb2_which_events(context)
            let needsWrite = (events & Int32(POLLOUT)) != 0

            if needsWrite && !writeSourceResumed {
                if writeSource == nil {
                    writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    writeSource?.setEventHandler { [weak self] in
                        self?.onEvent()
                    }
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
                    writeSource.resume() // Must resume before cancel
                }
                writeSource.cancel()
            }
            writeSource = nil
        }

        deinit {
            cancel()
        }
    }

    /// Called by SocketMonitor when the socket has events.
    /// Runs on the event loop queue. Services all ready I/O.
    private func handleSocketEvent() {
        guard let context else { return }

        // Determine what events to service
        let events = smb2_which_events(context)
        var revents: Int32 = 0

        // Check read readiness
        var pfd = pollfd()
        pfd.fd = smb2_get_fd(context)
        pfd.events = Int16(truncatingIfNeeded: events)

        // Non-blocking poll to check actual readiness
        if poll(&pfd, 1, 0) > 0 {
            revents = Int32(pfd.revents)
        } else {
            // DispatchSource fired but poll says nothing ready yet — try POLLIN
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
            failAllPendingOperations(
                with: POSIXError(.ECONNRESET, description: errorMsg)
            )
            return
        }

        // Update write source based on whether libsmb2 has outgoing data
        socketMonitor?.activateWriteSourceIfNeeded(context: context)
    }

    /// Starts socket monitoring after a successful connect.
    private func startSocketMonitoring() {
        guard let context else { return }
        let fd = smb2_get_fd(context)
        guard fd >= 0 else { return }

        socketMonitor = SocketMonitor(fd: fd, queue: eventLoopQueue) { [weak self] in
            self?.handleSocketEvent()
        }
        socketMonitor?.activateWriteSourceIfNeeded(context: context)
    }

    /// Stops socket monitoring (e.g., on disconnect).
    private func stopSocketMonitoring() {
        socketMonitor?.cancel()
        socketMonitor = nil
    }

    /// Resumes all pending operations with an error (e.g., connection lost).
    private func failAllPendingOperations(with error: any Error) {
        for (_, cb) in pendingOperations {
            cb.error = error
            cb.semaphore.signal()
        }
        pendingOperations.removeAll()
    }
}

// MARK: Setting manipulation

extension SMB2Client {
    var workstation: String {
        get {
            (context?.pointee.workstation).map(String.init(cString:)) ?? ""
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
            (context?.pointee.domain).map(String.init(cString:)) ?? ""
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
            (context?.pointee.user).map(String.init(cString:)) ?? ""
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
            (context?.pointee.password).map(String.init(cString:)) ?? ""
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
            (context?.pointee.security_mode).flatMap(NegotiateSigning.init(rawValue:)) ?? []
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
            context?.pointee.seal ?? 0 != 0
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
            context?.pointee.sec ?? .undefined
        }
        set {
            eventLoopQueue.sync {
                guard let context else { return }
                smb2_set_authentication(context, .init(bitPattern: newValue.rawValue))
            }
        }
    }

    var clientGuid: UUID? {
        guard let guid = try? smb2_get_client_guid(context.unwrap()) else {
            return nil
        }
        let uuid = UnsafeRawPointer(guid).assumingMemoryBound(to: uuid_t.self).pointee
        return UUID(uuid: uuid)
    }

    var server: String? {
        context?.pointee.server.map(String.init(cString:))
    }

    var share: String? {
        context?.pointee.share.map(String.init(cString:))
    }

    var version: Version {
        (context?.pointee.dialect).map { Version(rawValue: UInt32($0)) } ?? .any
    }

    var passthrough: Bool {
        get {
            var result: Int32 = 0
            smb2_get_passthrough(context, &result)
            return result != 0
        }
        set {
            smb2_set_passthrough(context, newValue ? 1 : 0)
        }
    }

    var isConnected: Bool {
        fileDescriptor != -1
    }

    var fileDescriptor: Int32 {
        do {
            return try smb2_get_fd(context.unwrap())
        } catch {
            return -1
        }
    }

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
        (context?.pointee.max_transact_size).map(Int.init) ?? 65535
    }
}

// MARK: Connectivity

extension SMB2Client {
    func connect(server: String, share: String, user: String) throws {
        // Connect uses a temporary poll loop on the event loop queue since
        // DispatchSource can't be set up until we have a valid fd.
        var connectError: (any Error)?
        eventLoopQueue.sync {
            do {
                guard let context = self.context else {
                    throw POSIXError(.ENOTCONN)
                }
                var cb = CBData()
                let cbPtr = Unmanaged.passUnretained(cb).toOpaque()
                let result = smb2_connect_share_async(
                    context, server, share, user, SMB2Client.generic_handler, cbPtr
                )
                try POSIXError.throwIfError(result, description: self.error)
                try self.pollUntilComplete(&cb)
                try POSIXError.throwIfError(cb.result, description: self.error)

                // Connection established — start DispatchSource monitoring
                self.startSocketMonitoring()
            } catch {
                connectError = error
            }
        }
        if let connectError { throw connectError }
    }

    func disconnect() throws {
        stopSocketMonitoring()
        failAllPendingOperations(with: POSIXError(.ENOTCONN))
        _=try? async_await { context, cbPtr -> Int32 in
            smb2_disconnect_share_async(context, SMB2Client.generic_handler, cbPtr)
        }
    }

    func echo() throws {
        if !isConnected {
            throw POSIXError(.ENOTCONN)
        }
        try async_await { context, cbPtr -> Int32 in
            smb2_echo_async(context, SMB2Client.generic_handler, cbPtr)
        }
    }
}

// MARK: DCE-RPC

extension SMB2Client {
    func shareEnum() throws -> [SMB2Share] {
        try async_await(dataHandler: [SMB2Share].init) { context, cbPtr -> Int32 in
            smb2_share_enum_async(context, SHARE_INFO_1, SMB2Client.generic_handler, cbPtr)
        }.data
    }

    func shareEnumSwift() throws -> [SMB2Share] {
        // Connection to server service.
        let srvsvc = try SMB2FileHandle(path: "srvsvc", desiredAccess: [.read, .write], createDisposition: .open, on: self)
        // Bind command
        _ = try srvsvc.write(data: MSRPC.SrvsvcBindData())
        let recvBindData = try srvsvc.pread(offset: 0, length: Int(Int16.max))
        try MSRPC.validateBindData(recvBindData)

        // NetShareEnum request, Level 1 mean we need share name and remark.
        _ = try srvsvc.pwrite(data: MSRPC.NetShareEnumAllRequest(serverName: server!), offset: 0)
        let recvData = try srvsvc.pread(offset: 0)
        return try MSRPC.NetShareEnumAllLevel1(data: recvData).shares
    }
}

// MARK: File information

extension SMB2Client {
    func stat(_ path: String) throws -> smb2_stat_64 {
        var st = smb2_stat_64()
        try async_await { context, cbPtr -> Int32 in
            smb2_stat_async(context, path.canonical, &st, SMB2Client.generic_handler, cbPtr)
        }
        return st
    }

    func statvfs(_ path: String) throws -> smb2_statvfs {
        var st = smb2_statvfs()
        try async_await { context, cbPtr -> Int32 in
            smb2_statvfs_async(context, path.canonical, &st, SMB2Client.generic_handler, cbPtr)
        }
        return st
    }

    func readlink(_ path: String) throws -> String {
        try async_await(dataHandler: String.init) { context, cbPtr -> Int32 in
            smb2_readlink_async(context, path.canonical, SMB2Client.generic_handler, cbPtr)
        }.data
    }

    func symlink(_ path: String, to destination: String) throws {
        let file = try SMB2FileHandle(path: path, flags: O_RDWR | O_CREAT | O_EXCL | O_SYMLINK | O_SYNC, on: self)
        let reparse = IOCtl.SymbolicLinkReparse(path: destination, isRelative: true)
        try file.fcntl(command: .setReparsePoint, args: reparse)
    }
}

// MARK: File operation

extension SMB2Client {
    func mkdir(_ path: String) throws {
        try async_await { context, cbPtr -> Int32 in
            smb2_mkdir_async(context, path.canonical, SMB2Client.generic_handler, cbPtr)
        }
    }

    func rmdir(_ path: String) throws {
        try async_await { context, cbPtr -> Int32 in
            smb2_rmdir_async(context, path.canonical, SMB2Client.generic_handler, cbPtr)
        }
    }

    func unlink(_ path: String, type: smb2_stat_64.ResourceType = .file) throws {
        switch type {
        case .directory:
            throw POSIXError(.EINVAL, description: "Use rmdir() to delete a directory.")
        case .file:
            try async_await { context, cbPtr -> Int32 in
                smb2_unlink_async(context, path.canonical, SMB2Client.generic_handler, cbPtr)
            }
        case .link:
            let file = try SMB2FileHandle(path: path, flags: O_RDWR | O_SYMLINK, on: self)
            try file.setInfo(smb2_file_disposition_info(delete_pending: 1), infoClass: .disposition)
        default:
            preconditionFailure("Not supported file type.")
        }
    }

    func rename(_ path: String, to newPath: String) throws {
        try async_await { context, cbPtr -> Int32 in
            smb2_rename_async(
                context, path.canonical, newPath.canonical, SMB2Client.generic_handler, cbPtr
            )
        }
    }

    func truncate(_ path: String, toLength: UInt64) throws {
        try async_await { context, cbPtr -> Int32 in
            smb2_truncate_async(
                context, path.canonical, toLength, SMB2Client.generic_handler, cbPtr
            )
        }
    }
}

// MARK: Async operation handler

extension SMB2Client {
    /// Per-operation callback state. Each in-flight operation gets its own CBData.
    /// The calling thread waits on the semaphore; the callback (fired by smb2_service
    /// on the event loop queue) signals it when the reply arrives.
    private class CBData {
        var result: Int32 = .init(NTStatus.success.rawValue)
        let semaphore = DispatchSemaphore(value: 0)
        var dataHandler: ((UnsafeMutableRawPointer?) -> Void)?
        var error: (any Error)?
        var status: NTStatus {
            NTStatus(rawValue: result)
        }
    }

    /// Temporary poll loop used only during connect (before DispatchSource is set up).
    /// Runs on the event loop queue.
    private func pollUntilComplete(_ cb: inout CBData) throws {
        let startDate = Date()
        while cb.error == nil && cb.semaphore.wait(timeout: .now()) == .timedOut {
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

    /// Callback invoked by libsmb2 when an async operation completes.
    /// Runs on the event loop queue (called from smb2_service).
    /// Signals the semaphore to wake the waiting caller.
    static let generic_handler: smb2_command_cb = { smb2, status, command_data, cbdata in
        do {
            guard try smb2.unwrap().pointee.fd >= 0 else { return }
            let cbdata = Unmanaged<CBData>.fromOpaque(try cbdata.unwrap()).takeUnretainedValue()
            if NTStatus(rawValue: status) != .success {
                cbdata.result = status
            }
            cbdata.dataHandler?(command_data)
            cbdata.semaphore.signal()
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
    func async_await(execute handler: UnsafeContextHandler<Int32>) throws -> Int32 {
        try async_await(dataHandler: { _, _ in }, execute: handler).result
    }

    /// Submits an async libsmb2 operation to the event loop and waits for the reply.
    ///
    /// 1. Creates a CBData with a semaphore
    /// 2. Dispatches the libsmb2 async call to the event loop queue (sync, brief)
    /// 3. The event loop queue returns immediately after queuing the PDU
    /// 4. The calling thread waits on the semaphore
    /// 5. DispatchSource fires when the socket has a reply
    /// 6. smb2_service() calls generic_handler which signals the semaphore
    /// 7. The calling thread wakes up with the result
    ///
    /// Multiple operations can be in-flight simultaneously — each waits on its
    /// own semaphore while the event loop services all of them.
    @discardableResult
    func async_await<DataType>(
        dataHandler: @escaping ContextHandler<DataType>,
        execute handler: UnsafeContextHandler<Int32>
    )
        throws -> (result: Int32, data: DataType)
    {
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
        let cbPtr = Unmanaged.passUnretained(cb).toOpaque()
        let cbId = ObjectIdentifier(cb)

        // Dispatch setup to event loop queue (synchronous — just queues the PDU)
        var setupError: (any Error)?
        eventLoopQueue.sync {
            guard let context = self.context else {
                setupError = POSIXError(.ENOTCONN)
                return
            }
            do {
                let result = try handler(context, cbPtr)
                try POSIXError.throwIfError(result, description: self.error)
                self.pendingOperations[cbId] = cb
                self.socketMonitor?.activateWriteSourceIfNeeded(context: context)
            } catch {
                setupError = error
            }
        }
        if let setupError { throw setupError }

        // Wait for the callback to signal completion
        if timeout > 0 {
            if cb.semaphore.wait(timeout: .now() + timeout) == .timedOut {
                eventLoopQueue.sync { _ = self.pendingOperations.removeValue(forKey: cbId) }
                throw POSIXError(.ETIMEDOUT)
            }
        } else {
            cb.semaphore.wait()
        }

        // Remove from pending (may already be removed by error broadcast)
        eventLoopQueue.sync { _ = self.pendingOperations.removeValue(forKey: cbId) }

        // Check for errors
        if let error = cb.error { throw error }
        let cbResult = cb.result
        try POSIXError.throwIfError(cbResult, description: error)
        if let error = dataHandlerError { throw error }
        return try (cbResult, resultData.unwrap())
    }

    @discardableResult
    func async_await_pdu(execute handler: UnsafeContextHandler<UnsafeMutablePointer<smb2_pdu>?>)
        throws -> UInt32
    {
        try async_await_pdu(dataHandler: { _, _ in }, execute: handler).status
    }

    @discardableResult
    func async_await_pdu<DataType>(
        dataHandler: @escaping ContextHandler<DataType>,
        execute handler: UnsafeContextHandler<UnsafeMutablePointer<smb2_pdu>?>
    )
        throws -> (status: UInt32, data: DataType)
    {
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
        let cbPtr = Unmanaged.passUnretained(cb).toOpaque()
        let cbId = ObjectIdentifier(cb)

        var setupError: (any Error)?
        eventLoopQueue.sync {
            guard let context = self.context else {
                setupError = POSIXError(.ENOTCONN)
                return
            }
            do {
                let pdu = try handler(context, cbPtr).unwrap()
                smb2_queue_pdu(context, pdu)
                self.pendingOperations[cbId] = cb
                self.socketMonitor?.activateWriteSourceIfNeeded(context: context)
            } catch {
                setupError = error
            }
        }
        if let setupError { throw setupError }

        if timeout > 0 {
            if cb.semaphore.wait(timeout: .now() + timeout) == .timedOut {
                eventLoopQueue.sync { _ = self.pendingOperations.removeValue(forKey: cbId) }
                throw POSIXError(.ETIMEDOUT)
            }
        } else {
            cb.semaphore.wait()
        }

        eventLoopQueue.sync { _ = self.pendingOperations.removeValue(forKey: cbId) }

        if let error = cb.error { throw error }
        try POSIXError.throwIfErrorStatus(cb.status)
        if let error = dataHandlerError { throw error }
        return try (cb.status.rawValue, resultData.unwrap())
    }
}

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
    }

    let rawValue: UInt32

    var type: ShareType {
        ShareType(rawValue: rawValue & 0x0fff_ffff)!
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
