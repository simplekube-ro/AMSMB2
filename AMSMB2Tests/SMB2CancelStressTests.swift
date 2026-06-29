//
//  SMB2CancelStressTests.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Integration stress harness for fix-cbdata-cancel-race-uaf.
//
//  Submits reads of a sizeable file and cancels them mid-flight in a tight loop to surface the
//  CBData post-queue cancellation use-after-free empirically. This is the empirical UAF detector:
//  it is intended to be run under AddressSanitizer (and ideally ThreadSanitizer) against a live
//  server:
//
//      SMB_SERVER=smb://host SMB_SHARE=share SMB_USER=u SMB_PASSWORD=p \
//          swift test --disable-sandbox --sanitize=address \
//          --filter SMB2CancelStressTests
//
//  Skipped automatically when `SMB_SERVER` is unset (see SMBIntegrationTestCase).
//

import XCTest

#if canImport(Darwin)
@preconcurrency import Darwin
#else
import FoundationNetworking
#endif
@testable import AMSMB2

final class SMB2CancelStressTests: SMBIntegrationTestCase, @unchecked Sendable {

    /// WHEN reads of a sizeable file are started and cancelled at randomized sub-read delays in a
    /// tight loop
    /// THEN the process stays alive (no use-after-free on a late libsmb2 callback) and a final
    /// normal read still succeeds.
    ///
    /// Under the pre-fix code a `Task` cancelled in the window after the read PDU was queued frees
    /// the per-operation `CBData`; the later reply (or context teardown) then calls back into freed
    /// memory. This loop maximises the chance of hitting that window. Run under ASan/TSan for the
    /// strongest signal — without a sanitizer the freed-memory access may not crash on every run.
    func testConcurrentReadCancellationDoesNotCrash() async throws {
        let smb = try await makeConnectedManager()
        let file = fileName()

        addTeardownBlock {
            try? await smb.removeFile(atPath: file)
        }

        // A few MB so each read spans multiple round trips, widening the cancellation window.
        let payload = randomData(size: 4 * 1024 * 1024)
        try await smb.write(data: payload, toPath: file, progress: nil)

        let iterations = 250
        for index in 0..<iterations {
            let readTask = Task {
                let _: Data = try await smb.contents(atPath: file)
            }

            // Vary the delay by iteration so cancellation lands at different points across the
            // read: some before the first PDU is queued, many while reads are in flight, a few
            // after completion. Date/random are fine in tests.
            let delayNanos = UInt64.random(in: 0...(1_500_000 * UInt64(index % 7 + 1)))
            if delayNanos > 0 {
                try? await Task.sleep(nanoseconds: delayNanos)
            }
            readTask.cancel()

            do {
                _ = try await readTask.value
            } catch is CancellationError {
                // Expected for cancellations that landed mid-read.
            } catch {
                // A completed-or-failed read (e.g. the cancel landed after completion, or the
                // server reset) is acceptable; the harness only asserts the absence of a crash.
            }
        }

        // The process is still alive: a final normal read must succeed and round-trip the payload.
        let roundTripped: Data = try await smb.contents(atPath: file)
        XCTAssertEqual(roundTripped, payload,
            "a normal read must still succeed after the cancellation stress loop")
    }
}
