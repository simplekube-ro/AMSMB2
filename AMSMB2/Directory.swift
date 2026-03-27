//
//  Directory.swift
//  AMSMB2
//
//  Created by Amir Abbas on 5/20/18.
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation
import SMB2

typealias smb2dirPointer = UnsafeMutablePointer<smb2dir>?

/// - Note: This class is NOT thread-safe.
final class SMB2Directory: Collection {
    private let path: String
    private let client: SMB2Client
    private var handle: smb2dirPointer

    private init(path: String, client: SMB2Client, handle: smb2dirPointer) {
        self.path = path
        self.client = client
        self.handle = handle
    }

    static func open(_ path: String, on client: SMB2Client) async throws -> SMB2Directory {
        let (_, handle) = try await client.async_await(dataHandler: OpaquePointer.init) { context, cbPtr -> Int32 in
            smb2_opendir_async(context, path, SMB2Client.generic_handler, cbPtr)
        }
        return SMB2Directory(path: path, client: client, handle: .init(handle))
    }

    deinit {
        // Pass the pointer as an integer token to cross the Sendable boundary.
        let rawHandle = handle.map { UInt(bitPattern: $0) }
        client.fireAndForget { context in
            guard let rawHandle else { return }
            let handle = UnsafeMutablePointer<smb2dir>(bitPattern: rawHandle)
            smb2_closedir(context, handle)
        }
    }

    /// Materializes all directory entries inside the event loop queue so the raw
    /// context pointer never escapes to another thread.
    func makeIterator() -> IndexingIterator<[smb2dirent]> {
        let entries: [smb2dirent] = (try? client.withContext { context in
            smb2_rewinddir(context, self.handle)
            var result: [smb2dirent] = []
            while let entry = smb2_readdir(context, self.handle) {
                result.append(entry.pointee)
            }
            return result
        }) ?? []
        return entries.makeIterator()
    }

    var startIndex: Int { 0 }

    var endIndex: Int { count }

    @available(*, deprecated, message: "Use lazy enumeration instead of full-scan count.")
    var count: Int {
        (try? client.withContext { context in
            let savedPos = smb2_telldir(context, self.handle)
            defer { smb2_seekdir(context, self.handle, savedPos) }
            smb2_rewinddir(context, self.handle)
            var result = 0
            while smb2_readdir(context, self.handle) != nil { result += 1 }
            return result
        }) ?? 0
    }

    subscript(index: Int) -> smb2dirent {
        (try? client.withContext { context in
            let savedPos = smb2_telldir(context, self.handle)
            smb2_seekdir(context, self.handle, index)
            defer { smb2_seekdir(context, self.handle, savedPos) }
            return smb2_readdir(context, self.handle)?.pointee ?? smb2dirent()
        }) ?? smb2dirent()
    }

    func index(after index: Int) -> Int {
        index + 1
    }
}
