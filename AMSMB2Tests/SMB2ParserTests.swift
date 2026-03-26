//
//  SMB2ParserTests.swift
//  AMSMB2
//
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest

@testable import AMSMB2

class SMB2ParserTests: XCTestCase, @unchecked Sendable {

    // MARK: - MSRPC NetShareEnumAllLevel1 Parser Tests

    /// Builds a minimal valid NetShareEnumAll Level1 binary payload containing the given shares.
    ///
    /// Layout:
    /// - 44 bytes: header (zeroed, irrelevant to parser)
    /// - UInt32: share count
    /// - Per share: 12-byte _SHARE_INFO_1 (4 bytes name ptr, 4 bytes type, 4 bytes remark ptr)
    /// - Per share: NameContainer for name, then NameContainer for comment
    ///
    /// NameContainer: UInt32 maxCount, UInt32 offset(0), UInt32 actualCount, UTF16LE string (with nul),
    ///                optional 2-byte padding if actualCount is odd.
    private static func buildNetShareEnumPayload(
        shares: [(name: String, type: UInt32, comment: String)],
        truncateAtNamePadding truncateNameIdx: Int? = nil,
        truncateAtCommentPadding truncateCommentIdx: Int? = nil
    ) -> Data {
        let count = UInt32(shares.count)
        var data = Data()

        // 44-byte header (zeroed)
        data.append(contentsOf: [UInt8](repeating: 0, count: 44))
        // Share count
        appendUInt32(&data, count)

        // _SHARE_INFO_1 array (12 bytes each)
        for share in shares {
            appendUInt32(&data, 1)  // name pointer (non-zero = valid)
            appendUInt32(&data, share.type)
            appendUInt32(&data, 1)  // remark pointer (non-zero = valid)
        }

        // NameContainer pairs
        for (i, share) in shares.enumerated() {
            // Name NameContainer
            let nameData = share.name.data(using: .utf16LittleEndian)!
            let nameActualCount = UInt32(nameData.count / 2 + 1)  // includes nul terminator
            appendUInt32(&data, nameActualCount)  // maxCount
            appendUInt32(&data, 0)                // offset
            appendUInt32(&data, nameActualCount)  // actualCount
            data.append(nameData)
            // Nul terminator (2 bytes)
            appendUInt16(&data, 0)

            if nameActualCount % 2 == 1 {
                // Truncate right before padding if requested
                if let idx = truncateNameIdx, idx == i {
                    return data
                }
                appendUInt16(&data, 0)  // alignment padding
            }

            // Comment NameContainer
            let commentData = share.comment.data(using: .utf16LittleEndian)!
            let commentActualCount = UInt32(commentData.count / 2 + 1)
            appendUInt32(&data, commentActualCount)
            appendUInt32(&data, 0)
            appendUInt32(&data, commentActualCount)
            data.append(commentData)
            appendUInt16(&data, 0)

            if commentActualCount % 2 == 1 {
                if let idx = truncateCommentIdx, idx == i {
                    return data
                }
                appendUInt16(&data, 0)
            }
        }

        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    // MARK: Task 1.1 — Bounds check at name alignment padding

    func testMSRPCParserBoundsCheckNamePadding() {
        // Construct payload truncated right before name alignment padding.
        // Share name "AB" → actualCount=3 (odd) → parser will try offset += 2 for padding.
        // We truncate the data right before that padding, so the bounds check should throw EINVAL.
        let truncatedData = Self.buildNetShareEnumPayload(
            shares: [("AB", 0, "comment")],
            truncateAtNamePadding: 0
        )

        XCTAssertThrowsError(
            try MSRPC.NetShareEnumAllLevel1(data: truncatedData)
        ) { error in
            guard let posixError = error as? POSIXError else {
                XCTFail("Expected POSIXError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(posixError.code, .EINVAL)
        }
    }

    // MARK: Task 1.2 — Bounds check at comment alignment padding

    func testMSRPCParserBoundsCheckCommentPadding() {
        // Share with even-length name (no name padding) but odd-length comment that triggers
        // comment alignment padding. Truncate right before that padding.
        // Name "ABCD" → actualCount=5 (odd) — hmm, we need a name that does NOT trigger
        // name padding but a comment that DOES trigger comment padding.
        // actualCount is odd when character count is even (chars + nul = odd).
        // So: name "A" → actualCount=2 (even, no padding), comment "AB" → actualCount=3 (odd, padding).
        let truncatedData = Self.buildNetShareEnumPayload(
            shares: [("A", 0, "AB")],
            truncateAtCommentPadding: 0
        )

        XCTAssertThrowsError(
            try MSRPC.NetShareEnumAllLevel1(data: truncatedData)
        ) { error in
            guard let posixError = error as? POSIXError else {
                XCTFail("Expected POSIXError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(posixError.code, .EINVAL)
        }
    }

    // MARK: Task 1.3 — Valid payload regression test

    func testMSRPCParserValidPayload() throws {
        let payload = Self.buildNetShareEnumPayload(
            shares: [
                ("IPC$", 3, "Remote IPC"),
                ("Documents", 0, "Shared docs"),
            ]
        )

        let result = try MSRPC.NetShareEnumAllLevel1(data: payload)
        XCTAssertEqual(result.shares.count, 2)
        XCTAssertEqual(result.shares[0].name, "IPC$")
        XCTAssertEqual(result.shares[0].props.type, .ipc)
        XCTAssertEqual(result.shares[0].comment, "Remote IPC")
        XCTAssertEqual(result.shares[1].name, "Documents")
        XCTAssertEqual(result.shares[1].props.type, .diskTree)
        XCTAssertEqual(result.shares[1].comment, "Shared docs")
    }

    // MARK: Task 1.4 — DecodableResponse with output_count == 0

    func testDecodableResponseEmptyOutput() throws {
        // Verify that NetShareEnumAllLevel1 initialized with empty data doesn't crash.
        // When output_count == 0, DecodableResponse.init passes empty Data to init(data:).
        // The parser should throw (can't read count at offset 44) rather than crash.
        XCTAssertThrowsError(try MSRPC.NetShareEnumAllLevel1(data: Data()))
    }
}
