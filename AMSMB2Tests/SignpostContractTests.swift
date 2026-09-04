//
//  SignpostContractTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Pins the signpost identifier contract (design D5.1): the subsystem and category the library
//  emits under must be byte-identical to the instrument filter printed in `docs/PROFILING.md`.
//  Renaming either side without the other makes the documented Instruments filter silently
//  select no data, which is indistinguishable from "the code never ran" for an operator
//  following the procedure — so the two are asserted equal here.
//

#if canImport(Network)

import Foundation
import XCTest

@testable import AMSMB2

final class SignpostContractTests: XCTestCase, @unchecked Sendable {

    /// `docs/PROFILING.md`, located relative to this source file (`AMSMB2Tests/../docs`) so the
    /// test does not depend on the working directory of the test runner.
    private static var profilingDocumentURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AMSMB2Tests/
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("docs/PROFILING.md")
    }

    /// `scripts/profile-summary.sh`, located relative to this source file for the same reason.
    private static var summaryScriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AMSMB2Tests/
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("scripts/profile-summary.sh")
    }

    /// Extracts `key: value` from the fenced instrument-filter block of the procedure document.
    ///
    /// Only lines inside a ``` fence are considered, so prose mentioning the subsystem cannot
    /// satisfy the contract — the block an operator copies into Instruments is what is pinned.
    private static func fencedFilterValue(forKey key: String, in document: String) -> String? {
        var insideFence = false
        for rawLine in document.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            guard insideFence, line.hasPrefix("\(key):") else { continue }
            return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// WHEN the instrument filter named in `docs/PROFILING.md` is read
    /// THEN its subsystem and category equal `InboundSignposts.subsystem` / `.category`
    func testProfilingDocumentFilterMatchesEmittedIdentifiers() throws {
        let documentURL = Self.profilingDocumentURL
        guard let document = try? String(contentsOf: documentURL, encoding: .utf8) else {
            XCTFail("""
                docs/PROFILING.md is missing or unreadable at \(documentURL.path) — the \
                profiling procedure is part of this capability, and its instrument filter is \
                what pins the signpost identifiers.
                """)
            return
        }

        let documentedSubsystem = Self.fencedFilterValue(forKey: "subsystem", in: document)
        let documentedCategory = Self.fencedFilterValue(forKey: "category", in: document)

        XCTAssertEqual(
            documentedSubsystem, InboundSignposts.subsystem,
            "the subsystem in the documented instrument filter must match the emitted subsystem, "
                + "otherwise an operator following the procedure records no signpost data"
        )
        XCTAssertEqual(
            documentedCategory, InboundSignposts.category,
            "the category in the documented instrument filter must match the emitted category, "
                + "otherwise an operator following the procedure records no signpost data"
        )
    }

    /// WHEN the five signpost names the library emits are looked for in the procedure document
    ///      and in the summary script
    /// THEN each appears verbatim in both
    ///
    /// A renamed signpost still records perfectly: the script simply reports `count 0` for the
    /// old name, which an operator cannot tell apart from "that point never fired" — the exact
    /// failure the baseline is supposed to detect. The names are the join key between the
    /// emitting code, the documented metrics table and the script's parser, so they are pinned
    /// the same way the subsystem and category are.
    func testEmittedSignpostNamesAppearInProcedureAndSummaryScript() throws {
        let names: [StaticString] = [
            InboundSignposts.transportReadName,
            InboundSignposts.chunkName,
            InboundSignposts.recvDrainName,
            InboundSignposts.serviceDispatchName,
            InboundSignposts.servicePassName,
        ]

        let sources: [(label: String, url: URL)] = [
            ("docs/PROFILING.md", Self.profilingDocumentURL),
            ("scripts/profile-summary.sh", Self.summaryScriptURL),
        ]

        for source in sources {
            guard let contents = try? String(contentsOf: source.url, encoding: .utf8) else {
                XCTFail("\(source.label) is missing or unreadable at \(source.url.path)")
                continue
            }
            for name in names {
                let emitted = "\(name)"
                XCTAssertTrue(
                    contents.contains(emitted),
                    "\(source.label) does not mention the emitted signpost name '\(emitted)' — "
                        + "a rename on one side leaves the other silently reporting nothing"
                )
            }
        }
    }
}

#endif // canImport(Network)
