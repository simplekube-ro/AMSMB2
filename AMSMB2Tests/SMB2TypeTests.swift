//
//  SMB2TypeTests.swift
//  AMSMB2
//
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest

@testable import AMSMB2

class SMB2TypeTests: XCTestCase, @unchecked Sendable {

    // MARK: - SMB2Client

    func testSMB2ClientTimeout() throws {
        let client = try SMB2Client(timeout: 30)
        XCTAssertEqual(client.timeout, 30)
    }

    // MARK: - SMB2FileChangeType

    func testFileChangeTypeOptionSetUnion() {
        let combined: SMB2FileChangeType = [.fileName, .directoryName]
        XCTAssertTrue(combined.contains(.fileName))
        XCTAssertTrue(combined.contains(.directoryName))
        XCTAssertFalse(combined.contains(.size))
    }

    func testFileChangeTypeOptionSetIntersection() {
        let a: SMB2FileChangeType = [.fileName, .size, .write]
        let b: SMB2FileChangeType = [.size, .write, .access]
        let intersection = a.intersection(b)
        XCTAssertFalse(intersection.contains(.fileName))
        XCTAssertTrue(intersection.contains(.size))
        XCTAssertTrue(intersection.contains(.write))
        XCTAssertFalse(intersection.contains(.access))
    }

    func testFileChangeTypeDescription() {
        let single: SMB2FileChangeType = .fileName
        XCTAssertEqual(single.description, "File Name")

        let combined: SMB2FileChangeType = [.fileName, .size]
        XCTAssertTrue(combined.description.contains("File Name"))
        XCTAssertTrue(combined.description.contains("Size"))

        let empty: SMB2FileChangeType = []
        XCTAssertEqual(empty.description, "")
    }

    func testFileChangeTypeContentModify() {
        let contentModify = SMB2FileChangeType.contentModify
        XCTAssertTrue(contentModify.contains(.create))
        XCTAssertTrue(contentModify.contains(.write))
        XCTAssertTrue(contentModify.contains(.size))
        XCTAssertFalse(contentModify.contains(.fileName))
    }

    func testFileChangeTypeRecursive() {
        let withRecursive: SMB2FileChangeType = [.fileName, .recursive]
        XCTAssertTrue(withRecursive.contains(.recursive))
        XCTAssertTrue(withRecursive.contains(.fileName))
    }

    // MARK: - SMB2FileChangeAction

    func testFileChangeActionEquality() {
        let a = SMB2FileChangeAction.added
        let b = SMB2FileChangeAction.added
        XCTAssertEqual(a, b)

        let c = SMB2FileChangeAction.removed
        XCTAssertNotEqual(a, c)
    }

    func testFileChangeActionHashing() {
        let a = SMB2FileChangeAction.modified
        let b = SMB2FileChangeAction.modified
        XCTAssertEqual(a.hashValue, b.hashValue)

        var set: Set<SMB2FileChangeAction> = [.added, .removed, .modified]
        XCTAssertEqual(set.count, 3)
        set.insert(.added)
        XCTAssertEqual(set.count, 3)
    }

    func testFileChangeActionDescription() {
        XCTAssertEqual(SMB2FileChangeAction.added.description, "Added")
        XCTAssertEqual(SMB2FileChangeAction.removed.description, "Removed")
        XCTAssertEqual(SMB2FileChangeAction.modified.description, "Modified")
        XCTAssertEqual(SMB2FileChangeAction.renamedOldName.description, "Rename with Old name")
        XCTAssertEqual(SMB2FileChangeAction.renamedNewName.description, "Rename with New name")
        XCTAssertEqual(SMB2FileChangeAction.addedStream.description, "Added Stream")
        XCTAssertEqual(SMB2FileChangeAction.removedStream.description, "Removed Stream")
        XCTAssertEqual(SMB2FileChangeAction.modifiedStream.description, "Modified Stream")

        let unknown = SMB2FileChangeAction(rawValue: 0xFFFF)
        XCTAssertEqual(unknown.description, "Unknown Action")
    }

    // MARK: - SMB2FileChangeInfo

    func testFileChangeInfoEquality() {
        let a = SMB2FileChangeInfo(action: .added, fileName: "test.txt")
        let b = SMB2FileChangeInfo(action: .added, fileName: "test.txt")
        XCTAssertEqual(a, b)

        let c = SMB2FileChangeInfo(action: .removed, fileName: "test.txt")
        XCTAssertNotEqual(a, c)

        let d = SMB2FileChangeInfo(action: .added, fileName: "other.txt")
        XCTAssertNotEqual(a, d)
    }

    func testFileChangeInfoNilFileName() {
        let a = SMB2FileChangeInfo(action: .modified, fileName: nil)
        let b = SMB2FileChangeInfo(action: .modified, fileName: nil)
        XCTAssertEqual(a, b)

        let c = SMB2FileChangeInfo(action: .modified, fileName: "file.txt")
        XCTAssertNotEqual(a, c)
    }
}
