//
//  GlobalContextListRaceTests.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Regression test for the data race on libsmb2's process-global `active_contexts`
//  list. `smb2_init_context` (SMB2_LIST_ADD) and `smb2_destroy_context`
//  (SMB2_LIST_REMOVE) mutate that single global list with no internal lock — see
//  Dependencies/libsmb2/lib/init.c. Each SMB2Client runs teardown on its own
//  per-context event-loop queue, so a consumer that creates and destroys multiple
//  contexts concurrently (e.g. a connection pool driving parallel downloads /
//  preview generation) mutates the shared list from several threads at once. That
//  corrupts the `next` links and produces an EXC_BAD_ACCESS deep inside
//  smb2_destroy_context's SMB2_LIST_REMOVE.
//
//  WHY this matters: the crash is non-deterministic (it only fires when one
//  teardown's list traversal overlaps another create/teardown), so without a
//  static serialization point the corruption ships silently and surfaces as field
//  crashes. Creating and destroying contexts needs no network, so the race is
//  reproducible offline under ThreadSanitizer.
//
//  Expectation:
//    - Under `swift test --sanitize=thread`: WITHOUT the static context-list lock in
//      SMB2Client this reports a data race (and may crash); WITH the lock it is clean.
//    - Without a sanitizer: this is a stress test that must not hang or crash.
//

import XCTest
@testable import AMSMB2

final class GlobalContextListRaceTests: XCTestCase {
    /// Hammer `smb2_init_context` / `smb2_destroy_context` from many threads so their
    /// unsynchronized mutation of the global `active_contexts` list overlaps. The
    /// serialization lives in SMB2Client; this test fails (TSan race / crash) without it.
    func testConcurrentContextCreateDestroyDoesNotCorruptGlobalList() throws {
        let concurrency = 8
        let iterationsPerThread = 250
        let group = DispatchGroup()

        for _ in 0..<concurrency {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for _ in 0..<iterationsPerThread {
                    // init -> SMB2_LIST_ADD on the global list.
                    guard let client = try? SMB2Client(timeout: 1) else {
                        XCTFail("smb2_init_context failed")
                        return
                    }
                    // Dropping the last reference runs deinit -> shutdown ->
                    // smb2_destroy_context -> SMB2_LIST_REMOVE on the global list.
                    _ = client
                }
            }
        }

        let outcome = group.wait(timeout: .now() + 60)
        XCTAssertEqual(outcome, .success, "concurrent context churn hung — possible lock-ordering regression")
    }
}
