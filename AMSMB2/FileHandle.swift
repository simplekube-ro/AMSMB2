//
//  FileHandle.swift
//  AMSMB2
//
//  Created by Amir Abbas on 5/20/18.
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation
import SMB2
import SMB2.Raw

typealias smb2fh = OpaquePointer

#if os(Linux) || os(Android) || os(OpenBSD)
let O_SYMLINK: Int32 = O_NOFOLLOW
#endif

/// Thread-safe indexed result collector for pipelined operations.
/// Slots are written concurrently from multiple dispatch queue blocks and read
/// sequentially after `DispatchGroup.wait()` completes.
private final class PipelineCollector<T>: @unchecked Sendable {
    private var results: [Result<T, any Error>?]
    private let lock = NSLock()

    init(count: Int) {
        self.results = Array(repeating: nil, count: count)
    }

    func set(index: Int, result: Result<T, any Error>) {
        lock.withLock { results[index] = result }
    }

    /// Returns the result at `index`. Must only be called after `DispatchGroup.wait()`.
    func get(index: Int) throws -> T {
        guard let result = results[index] else {
            throw POSIXError(.EIO, description: "Pipeline result missing for chunk \(index).")
        }
        return try result.get()
    }
}

public final class SMB2FileHandle: @unchecked Sendable {
    private var client: SMB2Client
    private var handle: smb2fh?
    private let _handleLock = NSLock()

    /// Opens a file for reading at the given path.
    ///
    /// Operations on this handle are serialized through the client's internal lock.
    /// The handle is invalidated if the connection is dropped; do not use after disconnect.
    public convenience init(forReadingAtPath path: String, on client: SMB2Client) throws {
        try self.init(path, flags: O_RDONLY, on: client)
    }

    convenience init(forWritingAtPath path: String, on client: SMB2Client) throws {
        try self.init(path, flags: O_WRONLY, on: client)
    }

    convenience init(forUpdatingAtPath path: String, on client: SMB2Client) throws {
        try self.init(path, flags: O_RDWR | O_APPEND, on: client)
    }

    convenience init(forOverwritingAtPath path: String, on client: SMB2Client) throws {
        try self.init(path, flags: O_WRONLY | O_CREAT | O_TRUNC, on: client)
    }

    convenience init(forOutputAtPath path: String, on client: SMB2Client) throws {
        try self.init(path, flags: O_WRONLY | O_CREAT, on: client)
    }
    
    convenience init(forCreatingIfNotExistsAtPath path: String, on client: SMB2Client) throws {
        try self.init(path, flags: O_RDWR | O_CREAT | O_EXCL, on: client)
    }

    convenience init(
        path: String,
        opLock: OpLock = .none,
        impersonation: ImpersonationLevel = .impersonation,
        desiredAccess: Access = [.read, .write, .synchronize],
        fileAttributes: Attributes = [],
        shareAccess: ShareAccess = [.read, .write],
        createDisposition: CreateDisposition,
        createOptions: CreateOptions = [], on client: SMB2Client
    ) throws {
        var leaseData = opLock.leaseContext.map { Data($0.regions.joined()) } ?? .init()
        defer { withExtendedLifetime(leaseData) {} }
        let (_, result) = try path.replacingOccurrences(of: "/", with: "\\").withCString { path in
            try client.async_await_pdu(dataHandler: SMB2FileID.init) {
                context, cbPtr -> UnsafeMutablePointer<smb2_pdu>? in
                var req = smb2_create_request()
                req.requested_oplock_level = opLock.lockLevel
                req.impersonation_level = impersonation.rawValue
                req.desired_access = desiredAccess.rawValue
                req.file_attributes = fileAttributes.rawValue
                req.share_access = shareAccess.rawValue
                req.create_disposition = createDisposition.rawValue
                req.create_options = createOptions.rawValue
                req.name = path
                leaseData.withUnsafeMutableBytes {
                    req.create_context = $0.count > 0 ? $0.baseAddress?.assumingMemoryBound(to: UInt8.self) : nil
                    req.create_context_length = UInt32($0.count)
                }
                return smb2_cmd_create_async(context, &req, SMB2Client.generic_handler, cbPtr)
            }
        }
        try self.init(fileDescriptor: result.rawValue, on: client)
    }
    
    convenience init(path: String, flags: Int32, lock: OpLock = .none, on client: SMB2Client) throws {
        try self.init(
            path: path,
            opLock: lock,
            desiredAccess: .init(flags: flags),
            shareAccess: .init(flags: flags),
            createDisposition: .init(flags: flags),
            createOptions: .init(flags: flags),
            on: client
        )
    }

    init(fileDescriptor: smb2_file_id, on client: SMB2Client) throws {
        self.client = client
        var fileDescriptor = fileDescriptor
        self.handle = try client.withContext { context in
            smb2_fh_from_file_id(context, &fileDescriptor)
        }
    }

    // This initializer does not support O_SYMLINK.
    private init(_ path: String, flags: Int32, lock: OpLock = .none, on client: SMB2Client) throws {
        let (_, handle) = try client.async_await(dataHandler: OpaquePointer.init) {
            context, cbPtr -> Int32 in
            var leaseKey = lock.leaseContext.map { Data(value: $0.key) } ?? Data()
            return leaseKey.withUnsafeMutableBytes {
                smb2_open_async_with_oplock_or_lease(
                    context, path.canonical, flags,
                    lock.lockLevel, lock.leaseState.rawValue,
                    !$0.isEmpty ? $0.baseAddress : nil,
                    SMB2Client.generic_handler, cbPtr
                )
            }
        }
        self.client = client
        self.handle = handle
    }

    deinit {
        _handleLock.lock()
        let captured = handle
        handle = nil
        _handleLock.unlock()
        guard let captured else { return }
        // Use fire-and-forget to avoid blocking deinit on the event loop.
        // The pointer is passed as a raw integer to cross the Sendable boundary safely.
        let rawHandle = UInt(bitPattern: captured)
        client.fireAndForget { context in
            let fh = OpaquePointer(bitPattern: rawHandle)
            smb2_close_async(context, fh, SMB2Client.generic_handler_noop, nil)
        }
    }

    var fileId: UUID {
        .init(uuid: (try? smb2_get_file_id(handle.unwrap()).unwrap().pointee) ?? compound_file_id)
    }

    /// Closes the file handle synchronously. Safe to call from any thread.
    /// After calling, further operations on this handle will throw.
    public func close() {
        _handleLock.lock()
        let captured = handle
        handle = nil
        _handleLock.unlock()
        guard let captured else { return }
        let rawHandle = UInt(bitPattern: captured)
        client.fireAndForget { context in
            let fh = OpaquePointer(bitPattern: rawHandle)
            smb2_close_async(context, fh, SMB2Client.generic_handler_noop, nil)
        }
    }

    /// Returns file status. Serialized through the client's internal lock.
    public func fstat() throws -> smb2_stat_64 {
        let handle = try handle.unwrap()
        var st = smb2_stat_64()
        try client.async_await { context, cbPtr -> Int32 in
            smb2_fstat_async(context, handle, &st, SMB2Client.generic_handler, cbPtr)
        }
        return st
    }
    
    func setInfo<T>(_ value: T, type: InfoType = .file, infoClass: InfoClass) throws {
        try client.async_await_pdu(dataHandler: EmptyReply.init) {
            context, cbPtr -> UnsafeMutablePointer<smb2_pdu>? in
            var value = value
            return withUnsafeMutablePointer(to: &value) { buf in
                var req = smb2_set_info_request()
                req.file_id = fileId.uuid
                req.info_type = type.rawValue
                req.file_info_class = infoClass.rawValue
                req.input_data = .init(buf)
                return smb2_cmd_set_info_async(context, &req, SMB2Client.generic_handler, cbPtr)
            }
        }
    }
    
    func set(stat: smb2_stat_64, attributes: Attributes) throws {
        let bfi = smb2_file_basic_info(
            creation_time: smb2_timeval(
                tv_sec: .init(stat.smb2_btime),
                tv_usec: .init(stat.smb2_btime_nsec / 1000)
            ),
            last_access_time: smb2_timeval(
                tv_sec: .init(stat.smb2_atime),
                tv_usec: .init(stat.smb2_atime_nsec / 1000)
            ),
            last_write_time: smb2_timeval(
                tv_sec: .init(stat.smb2_mtime),
                tv_usec: .init(stat.smb2_mtime_nsec / 1000)
            ),
            change_time: smb2_timeval(
                tv_sec: .init(stat.smb2_ctime),
                tv_usec: .init(stat.smb2_ctime_nsec / 1000)
            ),
            file_attributes: attributes.rawValue
        )
        try setInfo(bfi, infoClass: .basic)
    }

    func ftruncate(toLength: UInt64) throws {
        let handle = try handle.unwrap()
        try client.async_await { context, cbPtr -> Int32 in
            smb2_ftruncate_async(context, handle, toLength, SMB2Client.generic_handler, cbPtr)
        }
    }

    /// Maximum read size supported by the server. Serialized through the client's internal lock.
    /// Returns `0` when the SMB context is unavailable (e.g., disconnected), signaling
    /// that the handle is no longer usable.
    public var maxReadSize: Int {
        (try? Int(client.withContext(smb2_get_max_read_size))) ?? 0
    }

    /// This value allows softer streaming
    var optimizedReadSize: Int {
        maxReadSize
    }

    @discardableResult
    func lseek(offset: Int64, whence: SeekWhence) throws -> Int64 {
        let handle = try handle.unwrap()
        let result = try client.withContext { context in
            smb2_lseek(context, handle, offset, whence.rawValue, nil)
        }
        try POSIXError.throwIfError(result, description: client.error)
        return result
    }

    func read(length: Int = 0) throws -> Data {
        precondition(
            length <= UInt32.max, "Length bigger than UInt32.max can't be handled by libsmb2."
        )

        let handle = try handle.unwrap()
        let count = length > 0 ? length : optimizedReadSize
        var buffer = client.bufferPool.checkout(minimumSize: count)
        defer { client.bufferPool.checkin(buffer) }
        buffer.count = count
        let result = try buffer.withUnsafeMutableBytes { buffer in
            try client.async_await { context, cbPtr -> Int32 in
                smb2_read_async(
                    context, handle, buffer.baseAddress, .init(buffer.count), SMB2Client.generic_handler, cbPtr
                )
            }
        }
        return Data(buffer.prefix(Int(result)))
    }

    /// Reads data at the specified offset without changing the file position.
    /// Serialized through the client's internal lock.
    public func pread(offset: UInt64, length: Int = 0) throws -> Data {
        precondition(
            length <= UInt32.max, "Length bigger than UInt32.max can't be handled by libsmb2."
        )

        let handle = try handle.unwrap()
        let count = length > 0 ? length : optimizedReadSize
        var buffer = client.bufferPool.checkout(minimumSize: count)
        defer { client.bufferPool.checkin(buffer) }
        buffer.count = count
        let result = try buffer.withUnsafeMutableBytes { buffer in
            try client.async_await { context, cbPtr -> Int32 in
                smb2_pread_async(
                    context, handle, buffer.baseAddress, .init(buffer.count), offset, SMB2Client.generic_handler,
                    cbPtr
                )
            }
        }
        return Data(buffer.prefix(Int(result)))
    }

    var maxWriteSize: Int {
        (try? Int(client.withContext(smb2_get_max_write_size))) ?? 0
    }

    var optimizedWriteSize: Int {
        maxWriteSize
    }

    func write<DataType: DataProtocol>(data: DataType) throws -> Int {
        precondition(
            data.count <= Int32.max, "Data bigger than Int32.max can't be handled by libsmb2."
        )

        let handle = try handle.unwrap()
        let result = try Data(data).withUnsafeBytes { buffer in
            try client.async_await { context, cbPtr -> Int32 in
                smb2_write_async(
                    context, handle, buffer.baseAddress, .init(buffer.count), SMB2Client.generic_handler, cbPtr
                )
            }
        }
        return Int(result)
    }

    func pwrite<DataType: DataProtocol>(data: DataType, offset: UInt64) throws -> Int {
        precondition(
            data.count <= Int32.max, "Data bigger than Int32.max can't be handled by libsmb2."
        )

        let handle = try handle.unwrap()
        let result = try Data(data).withUnsafeBytes { buffer in
            try client.async_await { context, cbPtr -> Int32 in
                smb2_pwrite_async(
                    context, handle, buffer.baseAddress, .init(buffer.count), offset, SMB2Client.generic_handler,
                    cbPtr
                )
            }
        }
        return Int(result)
    }

    func fsync() throws {
        let handle = try handle.unwrap()
        try client.async_await { context, cbPtr -> Int32 in
            smb2_fsync_async(context, handle, SMB2Client.generic_handler, cbPtr)
        }
    }
    
    /// Reads `totalLength` bytes starting at `offset` using pipelined pread requests.
    /// Up to `maxInFlight` requests are dispatched concurrently; results are returned
    /// in offset order. The handle pointer is captured as an integer token that is safe
    /// to pass across Sendable boundaries — the handle itself cannot be closed while
    /// this function is running because `group.wait()` completes before returning.
    func pipelinedRead(
        offset: UInt64, totalLength: Int64, chunkSize: Int = 0, maxInFlight: Int = 4
    ) throws -> Data {
        let handle = try handle.unwrap()
        let handleRaw = UInt(bitPattern: handle)
        let readSize = chunkSize > 0 ? chunkSize : optimizedReadSize
        let totalBytes = Int(totalLength)
        var result = Data(capacity: totalBytes)
        var currentOffset = offset

        while Int(currentOffset - offset) < totalBytes {
            let remaining = totalBytes - Int(currentOffset - offset)
            let windowChunks = min(maxInFlight, (remaining + readSize - 1) / readSize)

            let collector = PipelineCollector<Data>(count: windowChunks)
            let group = DispatchGroup()

            for i in 0..<windowChunks {
                let chunkOffset = currentOffset + UInt64(i * readSize)
                let chunkLen = min(readSize, remaining - i * readSize)
                guard chunkLen > 0 else { break }

                group.enter()
                let client = self.client
                DispatchQueue.global().async {
                    defer { group.leave() }
                    do {
                        let fh = OpaquePointer(bitPattern: handleRaw)!
                        var buffer = client.bufferPool.checkout(minimumSize: chunkLen)
                        defer { client.bufferPool.checkin(buffer) }
                        buffer.count = chunkLen
                        let bytesRead = try buffer.withUnsafeMutableBytes { buf -> Int32 in
                            try client.async_await { context, cbPtr -> Int32 in
                                smb2_pread_async(
                                    context, fh, buf.baseAddress, .init(buf.count),
                                    chunkOffset, SMB2Client.generic_handler, cbPtr
                                )
                            }
                        }
                        collector.set(index: i, result: .success(Data(buffer.prefix(Int(bytesRead)))))
                    } catch {
                        collector.set(index: i, result: .failure(error))
                    }
                }
            }

            group.wait()

            // Collect all chunks before committing — discard partial window on error.
            var windowData = [Data]()
            windowData.reserveCapacity(windowChunks)
            for i in 0..<windowChunks {
                windowData.append(try collector.get(index: i))
            }
            for chunk in windowData {
                result.append(chunk)
            }

            currentOffset += UInt64(windowChunks * readSize)
        }

        return result
    }

    /// Writes `data` starting at `offset` using pipelined pwrite requests.
    /// Up to `maxInFlight` requests are dispatched concurrently. The handle pointer
    /// is captured as an integer token — see `pipelinedRead` for the safety argument.
    ///
    /// - Note: On error, partial writes may have been committed to the server.
    ///   The remote file should be considered in an indeterminate state.
    func pipelinedWrite(data: Data, offset: UInt64, chunkSize: Int = 0, maxInFlight: Int = 4) throws -> Int {
        let handle = try handle.unwrap()
        let handleRaw = UInt(bitPattern: handle)
        let writeSize = chunkSize > 0 ? chunkSize : optimizedWriteSize
        var currentOffset = offset
        var dataOffset = 0
        var totalWritten = 0

        while dataOffset < data.count {
            let remaining = data.count - dataOffset
            let windowChunks = min(maxInFlight, (remaining + writeSize - 1) / writeSize)

            let collector = PipelineCollector<Int>(count: windowChunks)
            let group = DispatchGroup()

            for i in 0..<windowChunks {
                let chunkStart = dataOffset + i * writeSize
                let chunkLen = min(writeSize, data.count - chunkStart)
                guard chunkLen > 0 else { break }

                let chunkData = data[chunkStart..<(chunkStart + chunkLen)]
                let writeOffset = currentOffset + UInt64(i * writeSize)

                group.enter()
                let client = self.client
                DispatchQueue.global().async {
                    defer { group.leave() }
                    do {
                        let fh = OpaquePointer(bitPattern: handleRaw)!
                        let written = try chunkData.withUnsafeBytes { buffer -> Int32 in
                            try client.async_await { context, cbPtr -> Int32 in
                                smb2_pwrite_async(
                                    context, fh, buffer.baseAddress, .init(buffer.count),
                                    writeOffset, SMB2Client.generic_handler, cbPtr
                                )
                            }
                        }
                        collector.set(index: i, result: .success(Int(written)))
                    } catch {
                        collector.set(index: i, result: .failure(error))
                    }
                }
            }

            group.wait()

            // Collect all results before committing — throw on first error without
            // advancing offsets. Partial writes leave the file indeterminate.
            var windowWritten = [Int]()
            windowWritten.reserveCapacity(windowChunks)
            for i in 0..<windowChunks {
                windowWritten.append(try collector.get(index: i))
            }
            for written in windowWritten {
                totalWritten += written
            }

            dataOffset += windowChunks * writeSize
            currentOffset += UInt64(windowChunks * writeSize)
        }

        return totalWritten
    }

    func flock(_ op: LockOperation) throws {
        try client.async_await_pdu { context, dataPtr in
            var element = smb2_lock_element(
                offset: 0,
                length: 0,
                flags: op.smb2Flag,
                reserved: 0
            )
            return withUnsafeMutablePointer(to: &element) { element in
                var request = smb2_lock_request(
                    lock_count: 1,
                    lock_sequence_number: 0,
                    lock_sequence_index: 0,
                    file_id: fileId.uuid,
                    locks: element
                )
                return smb2_cmd_lock_async(context, &request, SMB2Client.generic_handler, dataPtr)
            }
        }
    }
    
    func changeNotify(for type: SMB2FileChangeType) throws -> [SMB2FileChangeInfo] {
        // Build the Change Notify PDU directly instead of using
        // smb2_notify_change_filehandle_async, which wraps the callback in
        // notify_change_cb. That wrapper calls smb2_close() (synchronous)
        // inside the callback, re-entering the event loop and crashing.
        let fid = fileId
        let flags: UInt16 = type.contains(.recursive) ? UInt16(SMB2_CHANGE_NOTIFY_WATCH_TREE) : 0
        let filter = type.completionFilter
        let dataHandler: SMB2Client.ContextHandler<[SMB2FileChangeInfo]> = { client, dataPtr in
            guard let dataPtr else { return [] }
            let reply = dataPtr.assumingMemoryBound(to: smb2_change_notify_reply.self).pointee
            guard reply.output_buffer_length > 0, let output = reply.output else { return [] }
            let fnc = UnsafeMutablePointer<smb2_file_notify_change_information>.allocate(capacity: 1)
            fnc.initialize(to: smb2_file_notify_change_information())
            defer {
                free_smb2_file_notify_change_information(client.rawContext, fnc)
            }
            var vec = smb2_iovec(buf: output, len: Int(reply.output_buffer_length), free: nil)
            smb2_decode_filenotifychangeinformation(client.rawContext, fnc, &vec, 0)
            var result = [SMB2FileChangeInfo]()
            var current: UnsafeMutablePointer<smb2_file_notify_change_information>? = fnc
            while let ptr = current {
                if ptr.pointee.name != nil {
                    result.append(SMB2FileChangeInfo(ptr.pointee))
                }
                current = ptr.pointee.next
            }
            return result
        }
        let (_, result) = try client.async_await_pdu(dataHandler: dataHandler) { context, cbPtr in
            var req = smb2_change_notify_request(
                flags: flags,
                output_buffer_length: 0xffff,
                file_id: fid.uuid,
                completion_filter: filter
            )
            return smb2_cmd_change_notify_async(context, &req, SMB2Client.generic_handler, cbPtr)
        }
        return result
    }

    @discardableResult
    func fcntl<DataType: DataProtocol, R: DecodableResponse>(
        command: IOCtl.Command, args: DataType = Data()
    ) throws -> R {
        defer { withExtendedLifetime(args) {} }
        var inputBuffer = [UInt8](args)
        return try inputBuffer.withUnsafeMutableBytes { buf in
            var req = smb2_ioctl_request(
                ctl_code: command.rawValue,
                file_id: fileId.uuid,
                input_offset: 0, input_count: .init(buf.count),
                max_input_response: 0,
                output_offset: 0, output_count: UInt32(client.maximumTransactionSize),
                max_output_response: 65535,
                flags: .init(SMB2_0_IOCTL_IS_FSCTL),
                input: buf.baseAddress
            )
            return try client.async_await_pdu(dataHandler: R.init) {
                context, cbPtr -> UnsafeMutablePointer<smb2_pdu>? in
                smb2_cmd_ioctl_async(context, &req, SMB2Client.generic_handler, cbPtr)
            }.data
        }
    }
    
    func fcntl<DataType: DataProtocol>(command: IOCtl.Command, args: DataType = Data()) throws {
        let _: AnyDecodableResponse = try fcntl(command: command, args: args)
    }
}

extension SMB2FileHandle {
    struct SeekWhence: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        var rawValue: Int32
        
        init(rawValue: Int32) {
            self.rawValue = rawValue
        }
        
        var description: String {
            switch self {
            case .set:
                return "Set"
            case .current:
                return "Current"
            case .end:
                return "End"
            default:
                return "Unknown"
            }
        }

        static let set = SeekWhence(rawValue: SEEK_SET)
        static let current = SeekWhence(rawValue: SEEK_CUR)
        static let end = SeekWhence(rawValue: SEEK_END)
    }
    
    struct LockOperation: OptionSet, Sendable {
        var rawValue: Int32
        
        static let shared = LockOperation(rawValue: LOCK_SH)
        static let exclusive = LockOperation(rawValue: LOCK_EX)
        static let unlock = LockOperation(rawValue: LOCK_UN)
        static let nonBlocking = LockOperation(rawValue: LOCK_NB)
        
        var smb2Flag: UInt32 {
            var result: UInt32 = 0
            if contains(.shared) { result |= 0x0000_0001 }
            if contains(.exclusive) { result |= 0x0000_0002 }
            if contains(.unlock) { result |= 0x0000_0004 }
            if contains(.nonBlocking) { result |= 0x0000_0010 }
            return result
        }
    }
    
    struct Attributes: OptionSet, Sendable {
        var rawValue: UInt32
        
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        static let readonly = Self(rawValue: SMB2_FILE_ATTRIBUTE_READONLY)
        static let hidden = Self(rawValue: SMB2_FILE_ATTRIBUTE_HIDDEN)
        static let system = Self(rawValue: SMB2_FILE_ATTRIBUTE_SYSTEM)
        static let directory = Self(rawValue: SMB2_FILE_ATTRIBUTE_DIRECTORY)
        static let archive = Self(rawValue: SMB2_FILE_ATTRIBUTE_ARCHIVE)
        static let normal = Self(rawValue: SMB2_FILE_ATTRIBUTE_NORMAL)
        static let temporary = Self(rawValue: SMB2_FILE_ATTRIBUTE_TEMPORARY)
        static let sparseFile = Self(rawValue: SMB2_FILE_ATTRIBUTE_SPARSE_FILE)
        static let reparsePoint = Self(rawValue: SMB2_FILE_ATTRIBUTE_REPARSE_POINT)
        static let compressed = Self(rawValue: SMB2_FILE_ATTRIBUTE_COMPRESSED)
        static let offline = Self(rawValue: SMB2_FILE_ATTRIBUTE_OFFLINE)
        static let notContentIndexed = Self(rawValue: SMB2_FILE_ATTRIBUTE_NOT_CONTENT_INDEXED)
        static let encrypted = Self(rawValue: SMB2_FILE_ATTRIBUTE_ENCRYPTED)
        static let integrityStream = Self(rawValue: SMB2_FILE_ATTRIBUTE_INTEGRITY_STREAM)
        static let noScrubData = Self(rawValue: SMB2_FILE_ATTRIBUTE_NO_SCRUB_DATA)
    }
    
    struct LeaseState: OptionSet, Sendable {
        var rawValue: UInt32
        
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        static let none = Self(rawValue: SMB2_LEASE_NONE)
        static let readCaching = Self(rawValue: SMB2_LEASE_READ_CACHING)
        static let handleCaching = Self(rawValue: SMB2_LEASE_HANDLE_CACHING)
        static let writeCaching = Self(rawValue: SMB2_LEASE_WRITE_CACHING)
    }
    
    enum OpLock: Sendable {
        case none
        case ii
        case exclusive
        case batch
        case lease(state: LeaseState, key: UUID)
        
        var lockLevel: UInt8 {
            switch self {
            case .none:
                .init(SMB2_OPLOCK_LEVEL_NONE)
            case .ii:
                .init(SMB2_OPLOCK_LEVEL_II)
            case .exclusive:
                .init(SMB2_OPLOCK_LEVEL_EXCLUSIVE)
            case .batch:
                .init(SMB2_OPLOCK_LEVEL_BATCH)
            case .lease:
                .init(SMB2_OPLOCK_LEVEL_LEASE)
            }
        }
        
        var leaseState: LeaseState {
            switch self {
            case .lease(let state, _):
                state
            default:
                .none
            }
        }
        
        var leaseContext: CreateLeaseContext? {
            switch self {
            case .lease(let state, let key):
                .init(state: state, key: key)
            default:
                nil
            }
        }
    }
    
    struct ImpersonationLevel: RawRepresentable, Hashable, Sendable {
        var rawValue: UInt32
        
        static let anonymous = Self(rawValue: SMB2_IMPERSONATION_ANONYMOUS)
        static let identification = Self(rawValue: SMB2_IMPERSONATION_IDENTIFICATION)
        static let impersonation = Self(rawValue: SMB2_IMPERSONATION_IMPERSONATION)
        static let delegate = Self(rawValue: SMB2_IMPERSONATION_DELEGATE)
    }
    
    struct Access: OptionSet, Sendable {
        var rawValue: UInt32
        
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        init(flags: Int32) {
            switch flags & O_ACCMODE {
            case O_RDWR:
                self = [.read, .write, .delete]
            case O_WRONLY:
                self = [.write, .delete]
            default:
                self = [.read]
            }
            if (flags & O_SYNC) != 0 {
                insert(.synchronize)
            }
        }
        
        /* Access mask common to all objects */
        static let fileReadEA = Self(rawValue: SMB2_FILE_READ_EA)
        static let fileWriteEA = Self(rawValue: SMB2_FILE_WRITE_EA)
        static let fileDeleteChild = Self(rawValue: SMB2_FILE_DELETE_CHILD)
        static let fileReadAttributes = Self(rawValue: SMB2_FILE_READ_ATTRIBUTES)
        static let fileWriteAttributes = Self(rawValue: SMB2_FILE_WRITE_ATTRIBUTES)
        static let delete = Self(rawValue: SMB2_DELETE)
        static let readControl = Self(rawValue: SMB2_READ_CONTROL)
        static let writeDACL = Self(rawValue: SMB2_WRITE_DACL)
        static let writeOwner = Self(rawValue: SMB2_WRITE_OWNER)
        static let synchronize = Self(rawValue: SMB2_SYNCHRONIZE)
        static let acessSystemSecurity = Self(rawValue: SMB2_ACCESS_SYSTEM_SECURITY)
        static let maximumAllowed = Self(rawValue: SMB2_MAXIMUM_ALLOWED)
        static let genericAll = Self(rawValue: SMB2_GENERIC_ALL)
        static let genericExecute = Self(rawValue: SMB2_GENERIC_EXECUTE)
        static let genericWrite = Self(rawValue: SMB2_GENERIC_WRITE)
        static let genericRead = Self(rawValue: SMB2_GENERIC_READ)
        
        /* Access mask unique for file/pipe/printer */
        static let readData = Self(rawValue: SMB2_FILE_READ_DATA)
        static let writeData = Self(rawValue: SMB2_FILE_WRITE_DATA)
        static let appendData = Self(rawValue: SMB2_FILE_APPEND_DATA)
        static let execute = Self(rawValue: SMB2_FILE_EXECUTE)
        
        /* Access mask unique for directories */
        static let listDirectory = Self(rawValue: SMB2_FILE_LIST_DIRECTORY)
        static let addFile = Self(rawValue: SMB2_FILE_ADD_FILE)
        static let addSubdirectory = Self(rawValue: SMB2_FILE_ADD_SUBDIRECTORY)
        static let traverse = Self(rawValue: SMB2_FILE_TRAVERSE)
        
        static let read: Access = [.readData, .readAttributes]
        static let write: Access = [.writeData, .appendData, .fileWriteAttributes, .fileWriteEA, .readControl]
        static let executeList: Access = [.execute, .readAttributes]
        
        private static let readAttributes: Access = [.fileReadAttributes, .fileReadEA, .readControl]
    }
    
    struct ShareAccess: OptionSet, Sendable {
        var rawValue: UInt32
        
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        init(flags: Int32) {
            switch flags & O_ACCMODE {
            case O_RDWR:
                self = [.read, .write]
            case O_WRONLY:
                self = [.write]
            default:
                self = [.read]
            }
        }
        
        static let read = Self(rawValue: SMB2_FILE_SHARE_READ)
        static let write = Self(rawValue: SMB2_FILE_SHARE_WRITE)
        static let delete = Self(rawValue: SMB2_FILE_SHARE_DELETE)
    }
    
    struct CreateDisposition: RawRepresentable, Sendable {
        var rawValue: UInt32
        
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        init(flags: Int32) {
            if (flags & O_CREAT) != 0 {
                if (flags & O_EXCL) != 0 {
                    self = .create
                } else if (flags & O_TRUNC) != 0 {
                    self = .overwriteIfExists
                } else {
                    self = .openIfExists
                }
            } else {
                if (flags & O_TRUNC) != 0 {
                    self = .overwrite
                } else {
                    self = .open
                }
            }
        }
        
        /// If the file already exists, supersede it. Otherwise, create the file.
        /// This value SHOULD NOT be used for a printer object.
        static let supersede = Self(rawValue: SMB2_FILE_SUPERSEDE)
        
        /// If the file already exists, return success; otherwise, fail the operation.
        /// MUST NOT be used for a printer object.
        static let open = Self(rawValue: SMB2_FILE_OPEN)
        
        /// If the file already exists, fail the operation; otherwise, create the file.
        static let create = Self(rawValue: SMB2_FILE_CREATE)
        
        /// Open the file if it already exists; otherwise, create the file.
        /// This value SHOULD NOT be used for a printer object.
        static let openIfExists = Self(rawValue: SMB2_FILE_OPEN_IF)
        
        /// Overwrite the file if it already exists; otherwise, fail the operation.
        /// MUST NOT be used for a printer object.
        static let overwrite = Self(rawValue: SMB2_FILE_OVERWRITE)
        
        /// Overwrite the file if it already exists; otherwise, create the file.
        /// This value SHOULD NOT be used for a printer object.
        static let overwriteIfExists = Self(rawValue: SMB2_FILE_OVERWRITE_IF)
    }
    
    struct CreateOptions: OptionSet, Sendable {
        var rawValue: UInt32
        
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        init(flags: Int32) {
            self = []
            if (flags & O_SYNC) != 0 {
                insert(.noIntermediateBuffering)
            }
            if (flags & O_DIRECTORY) != 0 {
                insert(.directoryFile)
            }
            if (flags & O_SYMLINK) != 0 {
                insert(.openReparsePoint)
            }
        }
        
        static let directoryFile = Self(rawValue: SMB2_FILE_DIRECTORY_FILE)
        static let writeThrough = Self(rawValue: SMB2_FILE_WRITE_THROUGH)
        static let sequentialOnly = Self(rawValue: SMB2_FILE_SEQUENTIAL_ONLY)
        static let noIntermediateBuffering = Self(rawValue: SMB2_FILE_NO_INTERMEDIATE_BUFFERING)
        static let synchronousIOAlert = Self(rawValue: SMB2_FILE_SYNCHRONOUS_IO_ALERT)
        static let synchronousIONonAlert = Self(rawValue: SMB2_FILE_SYNCHRONOUS_IO_NONALERT)
        static let nonDirectoryFile = Self(rawValue: SMB2_FILE_NON_DIRECTORY_FILE)
        static let completeIfOplocked = Self(rawValue: SMB2_FILE_COMPLETE_IF_OPLOCKED)
        static let noEAKnowledge = Self(rawValue: SMB2_FILE_NO_EA_KNOWLEDGE)
        static let randomAccess = Self(rawValue: SMB2_FILE_RANDOM_ACCESS)
        static let deleteOnClose = Self(rawValue: SMB2_FILE_DELETE_ON_CLOSE)
        static let openByFileID = Self(rawValue: SMB2_FILE_OPEN_BY_FILE_ID)
        static let openForBackupIntent = Self(rawValue: SMB2_FILE_OPEN_FOR_BACKUP_INTENT)
        static let noCompression = Self(rawValue: SMB2_FILE_NO_COMPRESSION)
        static let openRemoteInstance = Self(rawValue: SMB2_FILE_OPEN_REMOTE_INSTANCE)
        static let openRequiringOplock = Self(rawValue: SMB2_FILE_OPEN_REQUIRING_OPLOCK)
        static let disallowExclusive = Self(rawValue: SMB2_FILE_DISALLOW_EXCLUSIVE)
        static let reserveOpfilter = Self(rawValue: SMB2_FILE_RESERVE_OPFILTER)
        static let openReparsePoint = Self(rawValue: SMB2_FILE_OPEN_REPARSE_POINT)
        static let openNoRecall = Self(rawValue: SMB2_FILE_OPEN_NO_RECALL)
        static let openForFreeSpaceQuery = Self(rawValue: SMB2_FILE_OPEN_FOR_FREE_SPACE_QUERY)
    }
    
    struct CreateLeaseContext: EncodableArgument {
        typealias Element = UInt8
        
        private static let headerLength = 24
        private static let leaseLength = UInt32(SMB2_CREATE_REQUEST_LEASE_SIZE)
        
        var state: LeaseState
        var key: UUID
        var parentKey: UUID?
                
        var regions: [Data] {
            [
                .init(value: 0 as UInt32), // chain offset
                .init(value: 16 as UInt16), // tag offset
                .init(value: 4 as UInt16), // tag length lo
                .init(value: 0 as UInt16), // tag length up
                .init(value: UInt16(Self.headerLength)), // context offset
                .init(value: UInt32(Self.leaseLength)), // context length
                .init(value: 0x5271_4c73 as UInt32),
                .init(value: 0 as UInt32),
                .init(value: key),
                .init(value: state.rawValue),
                .init(value: parentKey != nil ? 0x0000_0004 : 0 as UInt32), // Flags
                .init(value: 0 as UInt64), // LeaseDuration
                .init(value: parentKey ?? .zero),
                .init(value: 4 as UInt16), // Epoch
                .init(value: 0 as UInt16), // Reserved
            ]
        }
        
        init(state: LeaseState, key: UUID, parentKey: UUID? = nil) {
            self.state = state
            self.key = key
            self.parentKey = parentKey
        }
    }

    struct InfoType: RawRepresentable, Sendable {
        var rawValue: UInt8
        
        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        static let file = Self(rawValue: SMB2_0_INFO_FILE)
        static let fileSystem = Self(rawValue: SMB2_0_INFO_FILESYSTEM)
        static let security = Self(rawValue: SMB2_0_INFO_SECURITY)
        static let quota = Self(rawValue: SMB2_0_INFO_QUOTA)
    }
    
    struct InfoClass: RawRepresentable, Sendable {
        var rawValue: UInt8
        
        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        static let directory = Self(rawValue: SMB2_FILE_DIRECTORY_INFORMATION)
        static let fullDirectory = Self(rawValue: SMB2_FILE_FULL_DIRECTORY_INFORMATION)
        static let bothDirectory = Self(rawValue: SMB2_FILE_BOTH_DIRECTORY_INFORMATION)
        static let basic = Self(rawValue: SMB2_FILE_BASIC_INFORMATION)
        static let standard = Self(rawValue: SMB2_FILE_STANDARD_INFORMATION)
        static let `internal` = Self(rawValue: SMB2_FILE_INTERNAL_INFORMATION)
        static let extendedAttribute = Self(rawValue: SMB2_FILE_EA_INFORMATION)
        static let access = Self(rawValue: SMB2_FILE_ACCESS_INFORMATION)
        static let name = Self(rawValue: SMB2_FILE_NAME_INFORMATION)
        static let rename = Self(rawValue: SMB2_FILE_RENAME_INFORMATION)
        static let link = Self(rawValue: SMB2_FILE_LINK_INFORMATION)
        static let named = Self(rawValue: SMB2_FILE_NAMES_INFORMATION)
        static let disposition = Self(rawValue: SMB2_FILE_DISPOSITION_INFORMATION)
        static let position = Self(rawValue: SMB2_FILE_POSITION_INFORMATION)
        static let fullExtendedAttribute = Self(rawValue: SMB2_FILE_FULL_EA_INFORMATION)
        static let mode = Self(rawValue: SMB2_FILE_MODE_INFORMATION)
        static let alignment = Self(rawValue: SMB2_FILE_ALIGNMENT_INFORMATION)
        static let all = Self(rawValue: SMB2_FILE_ALL_INFORMATION)
        static let endOfFile = Self(rawValue: SMB2_FILE_END_OF_FILE_INFORMATION)
        static let alternativeName = Self(rawValue: SMB2_FILE_ALTERNATE_NAME_INFORMATION)
        static let objectID = Self(rawValue: SMB2_FILE_OBJECT_ID_INFORMATION)
        static let attributeTag = Self(rawValue: SMB2_FILE_ATTRIBUTE_TAG_INFORMATION)
        static let normalizedName = Self(rawValue: SMB2_FILE_NORMALIZED_NAME_INFORMATION)
        static let id = Self(rawValue: SMB2_FILE_ID_INFORMATION)
    }
}

extension RawRepresentable where RawValue == UInt32 {
    init(rawValue: Int32) {
        self.init(rawValue: .init(bitPattern: rawValue))!
    }
}

extension RawRepresentable where RawValue: BinaryInteger {
    init(rawValue: Int32) {
        self.init(rawValue: .init(truncatingIfNeeded: rawValue))!
    }
}

extension smb2_stat_64 {
    struct ResourceType: RawRepresentable, Hashable, Sendable {
        var rawValue: UInt32
        
        static let file = Self(rawValue: SMB2_TYPE_FILE)
        static let directory = Self(rawValue: SMB2_TYPE_DIRECTORY)
        static let link = Self(rawValue: SMB2_TYPE_LINK)
        
        var urlResourceType: URLFileResourceType {
            switch self {
            case .directory:
                .directory
            case .file:
                .regular
            case .link:
                .symbolicLink
            default:
                .unknown
            }
        }
    }
    
    var resourceType: ResourceType {
        .init(rawValue: smb2_type)
    }
    
    var isDirectory: Bool {
        resourceType == .directory
    }

    func populateResourceValue(_ dic: inout [URLResourceKey: any Sendable]) {
        dic.reserveCapacity(11 + dic.count)
        dic[.fileSizeKey] = NSNumber(value: smb2_size)
        dic[.linkCountKey] = NSNumber(value: smb2_nlink)
        dic[.documentIdentifierKey] = NSNumber(value: smb2_ino)
        dic[.fileResourceTypeKey] = resourceType.urlResourceType
        dic[.isDirectoryKey] = NSNumber(value: resourceType == .directory)
        dic[.isRegularFileKey] = NSNumber(value: resourceType == .file)
        dic[.isSymbolicLinkKey] = NSNumber(value: resourceType == .link)

        dic[.contentModificationDateKey] = Date(
            timespec(tv_sec: Int(smb2_mtime), tv_nsec: Int(smb2_mtime_nsec))
        )
        dic[.attributeModificationDateKey] = Date(
            timespec(tv_sec: Int(smb2_ctime), tv_nsec: Int(smb2_ctime_nsec))
        )
        dic[.contentAccessDateKey] = Date(
            timespec(tv_sec: Int(smb2_atime), tv_nsec: Int(smb2_atime_nsec))
        )
        dic[.creationDateKey] = Date(
            timespec(tv_sec: Int(smb2_btime), tv_nsec: Int(smb2_btime_nsec))
        )
    }
}

extension UUID {
    static let zero = UUID(uuid: uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
