//
//  SMBQUICCertificateProbeTests.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

//
//  Deterministic coverage of the SMB-over-QUIC certificate probe (design D1/D6) through the
//  internal `(server:timeout:driverFactory:deadline:)` entry point, driven by the same scripted
//  driver / fire-on-demand deadline doubles the transport tests use. Every row of the D1 outcome
//  table is exercised without a live handshake.
//

#if canImport(Network)

import Foundation
import XCTest
@testable import AMSMB2

@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
final class SMBQUICCertificateProbeTests: XCTestCase, @unchecked Sendable {
    private let capturedChain = [Data([0x30, 0x82, 0x01, 0x0A]), Data([0x30, 0x82, 0x02, 0x0B])]

    /// The TLS rejection the transport reports for a `complete(false)` verify block: `EPROTO`
    /// carrying the Security `OSStatus` as an `NSOSStatusErrorDomain` underlying error.
    private func tlsRejection() -> POSIXError {
        POSIXError(
            .EPROTO,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -9808)]
        )
    }

    /// Polls `predicate` (guarded by the doubles' locks) until true or the bound elapses.
    private func waitUntil(
        _ predicate: @escaping () -> Bool, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2000 {
            if predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
        XCTFail("timed out waiting: \(message)", file: file, line: line)
    }

    /// Launches the probe against a `ScriptedQUICDriver`, optionally pre-filling the capture slot
    /// from inside the driver factory (which stands in for the capture verify block firing before
    /// the handshake outcome is reported).
    private func launchProbe(
        driver: ScriptedQUICDriver, scheduler: ManualDeadlineScheduler,
        prefill: [Data]?, server: String = "fs.example.com", timeout: TimeInterval = 8
    ) -> Task<[Data], any Error> {
        Task {
            try await SMBQUICCertificateProbe.fetchServerCertificateChain(
                server: server, timeout: timeout,
                driverFactory: { _, _, slot in
                    if let prefill {
                        slot.store(prefill)
                    }
                    return driver
                },
                deadline: scheduler
            )
        }
    }

    private func expectEINVAL(
        _ body: @escaping () async throws -> [Data], _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("\(what) must be rejected", file: file, line: line)
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EINVAL, "\(what) must be EINVAL", file: file, line: line)
        } catch {
            XCTFail("expected EINVAL for \(what), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Capture slot (design D2)

    /// WHEN one queue stores a chain into the slot and another queue reads it
    /// THEN the read observes the stored chain — the lock supplies the cross-queue memory
    /// barrier the verify block (`verifyQueue`) → probe (cooperative pool) handoff needs. A fresh
    /// slot reads `nil`, which is what "nothing captured" means to the D1 table.
    func testCaptureSlotIsVisibleAcrossQueues() async {
        let slot = QUICCertificateCaptureSlot()
        XCTAssertNil(slot.chain, "a fresh slot has captured nothing")

        let stored = TestFlag()
        DispatchQueue(label: "probe.test.writer").async {
            slot.store(self.capturedChain)
            stored.set()
        }
        await waitUntil({ stored.isSet }, "writer queue stored the chain")

        let readBack = DispatchQueue(label: "probe.test.reader").sync { slot.chain }
        XCTAssertEqual(readBack, capturedChain, "the store must be visible from another queue")
    }

    /// WHEN an empty chain is stored — what `certificateChainDER` yields when Security.framework
    /// handed the verify block no certificates
    /// THEN the slot stays at "nothing captured", and an empty store after a real capture leaves
    /// the earlier chain in place. The invariant lives in the slot so the D1 table's `EPROTO` row
    /// cannot be turned into a bogus success by a zero-certificate handshake, and so a late empty
    /// store cannot erase a chain the probe is about to return.
    func testCaptureSlotIgnoresEmptyChain() {
        let slot = QUICCertificateCaptureSlot()
        slot.store([])
        XCTAssertNil(slot.chain, "an empty chain is not a capture")

        slot.store(capturedChain)
        slot.store([])
        XCTAssertEqual(slot.chain, capturedChain, "an empty store must not erase a real capture")
    }

    // MARK: - D1 outcome table

    /// (a) WHEN the chain was captured and the handshake is then rejected for a TLS reason
    /// THEN the probe returns the captured chain and does not throw — the server's rejection of
    /// our deliberate `complete(false)` is the *expected* outcome, not an error.
    func testFatalRejectionWithCapturedChainReturnsChain() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let task = launchProbe(driver: driver, scheduler: scheduler, prefill: capturedChain)

        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.waiting(tlsRejection(), .fatal))

        let chain = try await task.value
        XCTAssertEqual(chain, capturedChain, "leaf first, exactly what the verify block captured")
        XCTAssertEqual(driver.cancelCount, 1, "the started connection is cancelled exactly once")
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1, "the deadline is cancelled")
    }

    /// (b) WHEN the handshake is rejected for a TLS reason before any certificate was captured
    /// THEN the probe rethrows the transport's `EPROTO`, preserving the Security `OSStatus` as an
    /// `NSOSStatusErrorDomain` underlying error so callers can diagnose ALPN/TLS failures.
    func testFatalRejectionWithoutChainThrowsEPROTOWithUnderlyingOSStatus() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let task = launchProbe(driver: driver, scheduler: scheduler, prefill: nil)

        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.waiting(tlsRejection(), .fatal))

        do {
            _ = try await task.value
            XCTFail("a TLS rejection with no captured chain must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EPROTO)
            let underlying = (posix as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, NSOSStatusErrorDomain, "the OSStatus must survive")
        } catch {
            XCTFail("expected POSIXError(.EPROTO), got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
    }

    /// (c) WHEN the connection unexpectedly reports ready even though verification was rejected
    /// THEN the probe tears it down and returns the captured chain — no trusted-but-
    /// unauthenticated connection is left alive.
    func testReadyWithCapturedChainTearsDownAndReturnsChain() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let task = launchProbe(driver: driver, scheduler: scheduler, prefill: capturedChain)

        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.ready)

        let chain = try await task.value
        XCTAssertEqual(chain, capturedChain)
        XCTAssertEqual(driver.cancelCount, 1, "a ready connection must not outlive the probe")
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
    }

    /// (d) WHEN the connection reports ready and nothing was captured
    /// THEN the probe throws `EPROTO` — there is no chain to hand back, and the connection is
    /// still torn down.
    func testReadyWithoutChainThrowsEPROTO() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let task = launchProbe(driver: driver, scheduler: scheduler, prefill: nil)

        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.ready)

        do {
            _ = try await task.value
            XCTFail("ready with no captured chain must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EPROTO)
        } catch {
            XCTFail("expected POSIXError(.EPROTO), got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
    }

    /// (e) WHEN the deadline expires and nothing was captured
    /// THEN the probe throws `ETIMEDOUT` — an unreachable endpoint never hangs past `timeout`.
    func testDeadlineWithoutChainThrowsETIMEDOUT() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let task = launchProbe(driver: driver, scheduler: scheduler, prefill: nil)

        await waitUntil({ driver.didStart }, "driver started")
        scheduler.fireNow()

        do {
            _ = try await task.value
            XCTFail("deadline with no captured chain must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ETIMEDOUT)
        } catch {
            XCTFail("expected POSIXError(.ETIMEDOUT), got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
    }

    /// (f) WHEN the deadline expires *after* a chain was captured but before the rejection is
    /// reported
    /// THEN the probe returns the captured chain rather than `ETIMEDOUT` — the caller asked for
    /// the chain and it has one (design D1, deliberate).
    func testDeadlineWithCapturedChainReturnsChain() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let task = launchProbe(driver: driver, scheduler: scheduler, prefill: capturedChain)

        await waitUntil({ driver.didStart }, "driver started")
        scheduler.fireNow()

        let chain = try await task.value
        XCTAssertEqual(chain, capturedChain)
        XCTAssertEqual(driver.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
    }

    /// (g) WHEN the calling task is cancelled while the handshake is in flight, even with a chain
    /// already captured
    /// THEN the probe throws `CancellationError` — a cancelled task must never observe a success
    /// value — and the connection is still torn down exactly once.
    func testCancellationWhileWaitingThrowsEvenWithCapturedChain() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let task = launchProbe(driver: driver, scheduler: scheduler, prefill: capturedChain)

        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.waiting(POSIXError(.ETIMEDOUT), .transient)) // still trying.
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled probe must not return a chain")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
    }

    /// (h) WHEN the task is cancelled after the connection object exists but before the attempt
    /// is committed
    /// THEN the probe throws `CancellationError`, the connection was never started, and no cancel
    /// was issued — there is nothing live to cancel.
    func testCancellationBeforeCommitNeverStartsOrCancels() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        // The factory runs inside this task, so `withUnsafeCurrentTask` cancels the probe's own
        // task — never the XCTest method's task, which must stay usable for the assertions below.
        let task = Task {
            try await SMBQUICCertificateProbe.fetchServerCertificateChain(
                server: "fs.example.com", timeout: 8,
                driverFactory: { _, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return driver
                },
                deadline: scheduler
            )
        }

        do {
            _ = try await task.value
            XCTFail("cancel before commit must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertFalse(driver.didStart, "no connection was ever started")
        XCTAssertEqual(driver.cancelCount, 0, "nothing live to cancel")
    }

    /// WHEN the capture happens only during teardown (a driver that stores from its `cancel()`)
    /// THEN the probe still returns that chain — proving the slot is read strictly *after*
    /// `await close()` returned, so no verify-block write can still be in flight.
    func testSlotIsReadAfterCloseReturned() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let chain = capturedChain
        let task = Task {
            try await SMBQUICCertificateProbe.fetchServerCertificateChain(
                server: "fs.example.com", timeout: 8,
                driverFactory: { _, _, probeSlot in
                    // Store strictly during the probe's `await transport.close()`: a probe that
                    // snapshotted the slot earlier would see nothing and throw `EPROTO`.
                    driver.onCancel = { probeSlot.store(chain) }
                    return driver
                },
                deadline: scheduler
            )
        }

        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.ready)

        let returnedChain = try await task.value
        XCTAssertEqual(
            returnedChain, capturedChain, "a chain stored during close() must still be observed"
        )
        XCTAssertEqual(driver.cancelCount, 1)
    }

    // MARK: - Validation before any network activity (spec: probe validation contract)

    /// WHEN `server` names a numeric host or carries an out-of-range port, or `timeout` is not a
    /// finite positive number
    /// THEN the probe throws `EINVAL` and never invokes the driver factory — validation precedes
    /// every possibility of network activity.
    func testInvalidServerOrTimeoutThrowsEINVALWithoutBuildingADriver() async {
        for server in ["192.168.1.10", "[::1]", "fs.example.com:0", "fs.example.com:65536"] {
            let built = TestFlag()
            await expectEINVAL({
                try await SMBQUICCertificateProbe.fetchServerCertificateChain(
                    server: server, timeout: 8,
                    driverFactory: { _, _, _ in
                        built.set()
                        return ScriptedQUICDriver()
                    },
                    deadline: ManualDeadlineScheduler()
                )
            }, "server \(server)")
            XCTAssertFalse(built.isSet, "no driver may be built for \(server)")
        }

        for timeout in [0.0, -1.0, Double.nan, Double.infinity] {
            let built = TestFlag()
            await expectEINVAL({
                try await SMBQUICCertificateProbe.fetchServerCertificateChain(
                    server: "fs.example.com", timeout: timeout,
                    driverFactory: { _, _, _ in
                        built.set()
                        return ScriptedQUICDriver()
                    },
                    deadline: ManualDeadlineScheduler()
                )
            }, "timeout \(timeout)")
            XCTAssertFalse(built.isSet, "no driver may be built for timeout \(timeout)")
        }
    }

    /// WHEN `timeout` exceeds the 3600 s ceiling
    /// THEN the armed deadline is clamped to 3600 s — the probe reuses the QUIC connect-timeout
    /// normalization rather than defining a second rule.
    func testOversizedTimeoutClampsTo3600() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let task = launchProbe(
            driver: driver, scheduler: scheduler, prefill: capturedChain, timeout: 4000
        )

        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.ready)

        _ = try await task.value
        XCTAssertEqual(scheduler.scheduledTimeout, 3600, "timeouts above the ceiling clamp")
    }
}

#else

import XCTest
@testable import AMSMB2

/// Linux-only: the probe is declared on every platform and rejects with the `ENOTSUP` errno (the
/// `POSIXErrorCode` bridge shows it as `.EOPNOTSUPP` — ENOTSUP == EOPNOTSUPP on Linux) **before**
/// any validation or network activity — so a numeric host yields `ENOTSUP`, not `EINVAL`, the
/// same ordering as `SMB2Manager.connectShare`'s `.quic` rejection (design D4/D5).
final class SMBQUICCertificateProbeLinuxTests: XCTestCase {
    func testProbeThrowsENOTSUPBeforeValidation() async {
        for server in ["fs.example.com", "192.168.1.10"] {
            do {
                _ = try await SMBQUICCertificateProbe.fetchServerCertificateChain(server: server, timeout: 0)
                XCTFail("the probe must throw ENOTSUP on Linux (\(server))")
            } catch let error as POSIXError {
                XCTAssertEqual(error.code, .EOPNOTSUPP, "\(server): must be ENOTSUP, never EINVAL")
            } catch {
                XCTFail("expected POSIXError(ENOTSUP), got \(error)")
            }
        }
    }
}

#endif // canImport(Network)
