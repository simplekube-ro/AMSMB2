//
//  Parsers.swift
//  AMSMB2
//
//  Created by Amir Abbas on 10/29/19.
//  Copyright © 2019 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation
import SMB2
import SMB2.Raw

struct EmptyReply: DecodableResponse {
    init(data _: Data) throws {}
    init(_: SMB2Client, _: UnsafeMutableRawPointer?) throws {}
}

extension String {
    init(_: SMB2Client, _ dataPtr: UnsafeMutableRawPointer?) throws {
        self = try String(cString: dataPtr.unwrap().assumingMemoryBound(to: Int8.self))
    }
}

extension Array where Element == SMB2Share {
    init(_ client: SMB2Client, _ dataPtr: UnsafeMutableRawPointer?) throws {
        defer { smb2_free_data(client.rawContext, dataPtr) }
        let result = try dataPtr.unwrap().assumingMemoryBound(to: srvsvc_NetrShareEnum_rep.self).pointee
        self = Array(result.ses.ShareEnum.Level1)
    }

    // srvsvc_SHARE_INFO_1_CONTAINER is the fork's replacement for the upstream's
    // srvsvc_SHARE_INFO_1_carray: same share_info_1 pointer, EntriesRead for count.
    //
    // netname and remark are PTR_UNIQUE NDR referents: the C decoder (lib/dcerpc-srvsvc.c)
    // calls calloc-zeroed smb2_alloc_data for each entry, then decodes each field via
    // ndr_decode_ptr.  When the server sends a null referent ID (legal for remark, and
    // defensively also handled for netname), ndr_decode_ptr returns early leaving the field
    // as the calloc zero — i.e. a null char *.
    //
    // Swift imports unannoted char * struct fields as non-optional UnsafeMutablePointer<CChar>,
    // so we cannot use .map on the pointer directly.  Instead we use
    // UnsafePointer<CChar>.init?(bitPattern:), whose Optional initialiser returns nil when the
    // address is zero, matching the .map(String.init(cString:)) ?? "" convention used
    // throughout Context.swift (lines 341-377).
    init(_ container: srvsvc_SHARE_INFO_1_CONTAINER) {
        self = [srvsvc_SHARE_INFO_1](
            UnsafeBufferPointer(start: container.share_info_1, count: Int(container.EntriesRead))
        ).map { info in
            SMB2Share(
                name: UnsafePointer<CChar>(bitPattern: UInt(bitPattern: info.netname))
                    .map(String.init(cString:)) ?? "",
                props: .init(rawValue: info.type),
                comment: UnsafePointer<CChar>(bitPattern: UInt(bitPattern: info.remark))
                    .map(String.init(cString:)) ?? ""
            )
        }
    }
}

extension Array where Element == SMB2FileChangeInfo {
    init(_: SMB2Client, _ dataPtr: UnsafeMutableRawPointer?) throws {
        var result = [SMB2FileChangeInfo]()
        dataPtr?.withMemoryRebound(to: smb2_file_notify_change_information.self, capacity: 1) { ptr in
            var ptr = ptr
            if ptr.pointee.name != nil {
                result.append(.init(ptr.pointee))
            }
            
            while ptr.pointee.next != nil {
                if ptr.pointee.name != nil {
                    result.append(.init(ptr.pointee))
                }
                ptr = ptr.pointee.next
            }
        }
        self = result
    }
}

extension OpaquePointer {
    init(_: SMB2Client, _ dataPtr: UnsafeMutableRawPointer?) throws {
        self = try OpaquePointer(dataPtr.unwrap())
    }
}

struct SMB2FileID: RawRepresentable {
    let rawValue: smb2_file_id
    
    init?(rawValue: smb2_file_id) {
        self.rawValue = rawValue
    }
    
    init(_: SMB2Client, _ dataPtr: UnsafeMutableRawPointer?) throws {
        self.rawValue = try dataPtr.unwrap().assumingMemoryBound(to: smb2_create_reply.self).pointee
            .file_id
    }
}

extension DecodableResponse {
    init(_ client: SMB2Client, _ dataPtr: UnsafeMutableRawPointer?) throws {
        let reply = try dataPtr.unwrap().assumingMemoryBound(to: smb2_ioctl_reply.self).pointee
        guard reply.output_count > 0, let output = reply.output else {
            self = try Self(data: .init())
            return
        }
        defer { smb2_free_data(client.rawContext, output) }
        let data = Data(bytes: output, count: Int(reply.output_count))
        self = try Self(data: data)
    }
}
