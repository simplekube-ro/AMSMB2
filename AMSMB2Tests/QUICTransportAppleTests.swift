//
//  QUICTransportAppleTests.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

#if canImport(Network)

import Foundation
import XCTest
@testable import AMSMB2

// MARK: - Test doubles (design D7 seams)

/// A tiny lock-guarded boolean flag settable from a synchronous closure and pollable from an
/// async test (avoids `DispatchSemaphore.wait()`, which is unavailable in async contexts).
final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

/// A scripted `QUICConnectionDriver`: records `cancel()`/`start`, delivers state and inbound
/// events on demand from the test thread, and never auto-emits `.cancelled` (so tests own every
/// interleaving).
final class ScriptedQUICDriver: QUICConnectionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var onState: (@Sendable (QUICConnectionState) -> Void)?
    private var onReceive: (@Sendable (Result<Data, POSIXError>) -> Void)?
    private var _started = false
    private var _cancelCount = 0
    private var _sentChunks: [Data] = []

    func start(
        onState: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive: @escaping @Sendable (Result<Data, POSIXError>) -> Void
    ) {
        lock.withLock {
            self.onState = onState
            self.onReceive = onReceive
            self._started = true
        }
    }

    func cancel() {
        lock.withLock { _cancelCount += 1 }
    }

    func send(_ bytes: Data) async throws {
        lock.withLock { _sentChunks.append(bytes) }
    }

    // MARK: Test control

    func emit(_ state: QUICConnectionState) {
        let handler = lock.withLock { onState }
        handler?(state)
    }

    func deliver(_ result: Result<Data, POSIXError>) {
        let handler = lock.withLock { onReceive }
        handler?(result)
    }

    var didStart: Bool {
        lock.withLock { _started }
    }

    var cancelCount: Int {
        lock.withLock { _cancelCount }
    }

    var sentChunks: [Data] {
        lock.withLock { _sentChunks }
    }
}

/// A fire-on-demand `ConnectDeadlineScheduler`. `cancel()` only records (keeps the fire closure)
/// so a test can still call `fireNow()` afterwards to prove a post-ready deadline is a no-op.
final class ManualDeadlineScheduler: ConnectDeadlineScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var fire: (@Sendable () -> Void)?
    private var _scheduledTimeout: TimeInterval?
    private var _cancelCount = 0

    func schedule(after timeout: TimeInterval, fire: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.fire = fire
            self._scheduledTimeout = timeout
        }
    }

    func cancel() {
        lock.withLock { _cancelCount += 1 }
    }

    // MARK: Test control

    func fireNow() {
        let fire = lock.withLock { self.fire }
        fire?()
    }

    var scheduledTimeout: TimeInterval? {
        lock.withLock { _scheduledTimeout }
    }

    var cancelCount: Int {
        lock.withLock { _cancelCount }
    }
}

/// A `ConnectDeadlineScheduler` that fires **synchronously inside `schedule()`** — used to drive
/// the "deadline wins the claim before `driver.start()`" regression deterministically.
final class ImmediateFireScheduler: ConnectDeadlineScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelCount = 0
    func schedule(after _: TimeInterval, fire: @escaping @Sendable () -> Void) {
        fire()
    }

    func cancel() {
        lock.withLock { _cancelCount += 1 }
    }

    var cancelCount: Int {
        lock.withLock { _cancelCount }
    }
}

// MARK: - Tests

@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
final class QUICTransportAppleTests: XCTestCase, @unchecked Sendable {
    // MARK: Helpers

    private func makeTransport(
        _ driver: ScriptedQUICDriver,
        _ scheduler: ManualDeadlineScheduler,
        configuration: SMBQUICConfiguration = SMBQUICConfiguration(),
        connectTimeout: TimeInterval = 30
    ) -> QUICTransportApple {
        QUICTransportApple(
            configuration: configuration,
            connectTimeout: connectTimeout,
            driverFactory: { _, _, _ in driver },
            deadline: scheduler
        )
    }

    /// Polls `predicate` (state guarded by the doubles' locks) until true or the bound elapses.
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

    // MARK: - 2.2 Skeleton / close / receive contracts

    /// Never-connected `receive()` → `ENOTCONN` (reserved for the never-connected case).
    func testReceiveOnNeverConnectedThrowsENOTCONN() async {
        let transport = makeTransport(ScriptedQUICDriver(), ManualDeadlineScheduler())
        do {
            _ = try await transport.receive()
            XCTFail("never-connected receive must throw ENOTCONN")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ENOTCONN)
        } catch {
            XCTFail("expected POSIXError(.ENOTCONN), got \(error)")
        }
    }

    /// Double `close()` is a no-op and does not crash.
    func testDoubleCloseIsNoOp() async {
        let transport = makeTransport(ScriptedQUICDriver(), ManualDeadlineScheduler())
        await transport.close()
        await transport.close() // must not crash / double-release.
    }

    /// `receive()` after `close()` returns empty `Data` without throwing.
    func testReceiveAfterCloseReturnsEmptyData() async throws {
        let transport = makeTransport(ScriptedQUICDriver(), ManualDeadlineScheduler())
        await transport.close()
        let data = try await transport.receive()
        XCTAssertEqual(data, Data(), "receive after close is the close EOF signal")
    }

    // MARK: - 2.3 Connect state machine (design D7)

    /// Successful connect: `.ready` wins, the connection is retained (send works), and the
    /// deadline timer is cancelled while the connection is NOT cancelled.
    func testReadyResolvesSuccessAndKeepsConnection() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "fs.example.com", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        XCTAssertEqual(scheduler.scheduledTimeout, 30, "deadline armed from connectTimeout")
        driver.emit(.ready)
        try await task.value

        XCTAssertEqual(driver.cancelCount, 0, "ready must not cancel the connection")
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1, "ready must cancel the deadline timer")
        // Connection retained → send() reaches the driver (not ENOTCONN).
        try await transport.send(Data([0x01]))
        XCTAssertEqual(driver.sentChunks, [Data([0x01])])
    }

    /// `.waiting` is non-terminal (progress continues), then `.ready` still succeeds.
    func testWaitingIsNonTerminalThenReadySucceeds() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.setup)
        driver.emit(.preparing)
        driver.emit(.waiting(POSIXError(.ENETDOWN)))
        driver.emit(.ready)
        try await task.value // did not fail on .waiting.
    }

    /// `.failed` during connect maps to the `POSIXError` and cancels/releases the connection.
    func testFailedResolvesMappedPOSIXError() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.failed(POSIXError(.ECONNREFUSED)))

        do {
            try await task.value
            XCTFail("failed must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ECONNREFUSED)
        } catch {
            XCTFail("expected POSIXError, got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1, "a losing outcome cancels the connection exactly once")
    }

    /// Cancellation before start: the connect throws `CancellationError` and never starts the
    /// driver (no `NWConnection` is created). Deterministic via a gated driver factory.
    func testCancellationBeforeStartThrowsAndNeverStartsDriver() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let factoryEntered = TestFlag()
        let releaseFactory = DispatchSemaphore(value: 0)
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in
                factoryEntered.set()
                releaseFactory.wait() // hold connect between checkCancellation and the store.
                return driver
            },
            deadline: scheduler
        )

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ factoryEntered.isSet }, "factory entered")
        task.cancel()
        releaseFactory.signal() // signal() is async-safe (only wait() is not).

        do {
            try await task.value
            XCTFail("cancel before start must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertFalse(driver.didStart, "no NWConnection: the driver must never start")
        XCTAssertEqual(driver.cancelCount, 0, "nothing to cancel")
    }

    /// Cancellation while `.waiting`: the cancellation claims the outcome, cancels the connection
    /// exactly once, and connect throws `CancellationError`.
    func testCancellationWhileWaitingClaimsAndCancels() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.waiting(POSIXError(.ETIMEDOUT))) // driver holds .waiting.
        task.cancel()

        do {
            try await task.value
            XCTFail("cancellation while waiting must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1, "exactly one cancel() issued")
    }

    /// Ready-versus-cancel, ready wins: a cancel arriving after `.ready` performs NO `cancel()`
    /// and the connection stays usable.
    func testReadyWinsRaceLosingCancelHasNoSideEffect() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.ready)
        try await task.value // ready won.
        task.cancel() // losing cancel — task already finished.

        XCTAssertEqual(driver.cancelCount, 0, "ready-wins: the losing cancel must not cancel()")
        try await transport.send(Data([0x02]))
        XCTAssertEqual(driver.sentChunks, [Data([0x02])], "connection remains usable")
    }

    /// Ready-versus-cancel, cancel wins: cancellation claims first, then a late `.ready` is a
    /// no-op; connect throws `CancellationError`, exactly one `cancel()`.
    func testCancelWinsRaceLateReadyIsNoOp() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        task.cancel()
        // Give onCancel time to claim, then a late .ready must not resurrect success.
        await waitUntil({ driver.cancelCount == 1 }, "cancel claimed")
        driver.emit(.ready)

        do {
            try await task.value
            XCTFail("cancel-wins must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1, "cancel-wins: exactly one cancel(), late ready no-op")
    }

    /// Ready-versus-cancel, cancel wins, with a late `.failed` (sibling of the late-`.ready`
    /// case): cancellation claims first, then a late `.failed` is a no-op.
    func testCancelWinsRaceLateFailedIsNoOp() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        task.cancel()
        await waitUntil({ driver.cancelCount == 1 }, "cancel claimed")
        driver.emit(.failed(POSIXError(.ECONNREFUSED))) // late failure must not overwrite.

        do {
            try await task.value
            XCTFail("cancel-wins must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1, "cancel-wins: exactly one cancel(), late failed no-op")
    }

    /// Regression (should-fix): a deadline that wins the connect claim in the window **after** the
    /// continuation-store lock releases but **before** `driver.start()` must suppress the start
    /// entirely — the setup body performs no side effects once the claim is consumed (design D7).
    /// Driven deterministically by a scheduler that fires synchronously inside `schedule()`.
    func testDeadlineWinsBeforeStartSuppressesDriverStart() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ImmediateFireScheduler()
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 5,
            driverFactory: { _, _, _ in driver },
            deadline: scheduler
        )

        let task = Task { try await transport.connect(host: "h", port: 443) }
        do {
            try await task.value
            XCTFail("deadline win must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ETIMEDOUT)
        } catch {
            XCTFail("expected POSIXError(.ETIMEDOUT), got \(error)")
        }
        XCTAssertFalse(
            driver.didStart, "a claim consumed before start must suppress driver.start()"
        )
        XCTAssertEqual(driver.cancelCount, 0, "nothing was started → nothing is cancelled")
    }

    /// Failure-versus-cancel: whichever is emitted first wins; the other is a no-op. Here the
    /// failure wins and the late cancel performs nothing extra.
    func testFailureWinsRaceLateCancelIsNoOp() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.failed(POSIXError(.ECONNRESET)))

        do {
            try await task.value
            XCTFail("failure must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ECONNRESET)
        } catch {
            XCTFail("expected POSIXError, got \(error)")
        }
        task.cancel() // losing cancel on a finished task.
        XCTAssertEqual(driver.cancelCount, 1, "connection cancelled exactly once")
    }

    /// `close()` while connecting wins the claim: the connection is cancelled once and connect
    /// throws `POSIXError(.ECONNABORTED)`.
    func testCloseWhileConnectingThrowsECONNABORTED() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        await transport.close()

        do {
            try await task.value
            XCTFail("close while connecting must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ECONNABORTED)
        } catch {
            XCTFail("expected POSIXError(.ECONNABORTED), got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1, "close cancels the in-flight connection once")
    }

    /// Deadline expiry before `.ready`: the scheduler fires, the connection is cancelled once, and
    /// connect throws `POSIXError(.ETIMEDOUT)` whose description mentions the last `.waiting` error.
    func testDeadlineExpiryThrowsETIMEDOUT() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler, connectTimeout: 12)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.waiting(POSIXError(.EHOSTUNREACH)))
        scheduler.fireNow()

        do {
            try await task.value
            XCTFail("deadline expiry must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ETIMEDOUT)
            XCTAssertTrue(
                (posix as NSError).localizedDescription.contains("waiting"),
                "ETIMEDOUT description should mention the last waiting error"
            )
        } catch {
            XCTFail("expected POSIXError(.ETIMEDOUT), got \(error)")
        }
        XCTAssertEqual(driver.cancelCount, 1, "deadline cancels the connection once")
    }

    /// A deadline that fires AFTER `.ready` has won is a side-effect-free no-op.
    func testDeadlineAfterReadyIsNoOp() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.ready)
        try await task.value
        scheduler.fireNow() // post-ready deadline — must not cancel or double-resume.

        XCTAssertEqual(driver.cancelCount, 0, "post-ready deadline is a no-op")
        try await transport.send(Data([0x03]))
        XCTAssertEqual(driver.sentChunks, [Data([0x03])], "connection still usable")
    }

    // MARK: - 2.5 send / receive + D8 established-connection lifecycle

    /// Peer-originated graceful EOF: an empty inbound delivery resumes a parked `receive()` with
    /// empty `Data`.
    func testPeerGracefulEOFReturnsEmptyData() async throws {
        let (transport, driver) = try await connectedTransport()
        async let received = transport.receive()
        await waitUntil({ true }, "scheduled") // let receive() park.
        try? await Task.sleep(nanoseconds: 5_000_000)
        driver.deliver(.success(Data())) // stream EOF.
        let data = try await received
        XCTAssertEqual(data, Data(), "peer EOF surfaces as empty Data")
    }

    /// Inbound bytes buffer when they arrive before a `receive()`, then drain FIFO.
    func testInboundBuffersThenDrains() async throws {
        let (transport, driver) = try await connectedTransport()
        driver.deliver(.success(Data([0xaa, 0xbb])))
        driver.deliver(.success(Data([0xcc])))
        let first = try await transport.receive()
        let second = try await transport.receive()
        XCTAssertEqual(first, Data([0xaa, 0xbb]))
        XCTAssertEqual(second, Data([0xcc]))
    }

    /// Local close then `.cancelled`: the parked `receive()` sees empty `Data`, and the trailing
    /// `.cancelled` event is a no-op (never abnormal loss). Subsequent receive stays empty.
    func testLocalCloseThenCancelledIsNotAbnormalLoss() async throws {
        let (transport, driver) = try await connectedTransport()
        async let parked = transport.receive()
        try? await Task.sleep(nanoseconds: 5_000_000)
        await transport.close() // records local-close cause before cancel.
        let data = try await parked
        XCTAssertEqual(data, Data(), "local close resumes the parked receiver with empty Data")

        driver.emit(.cancelled) // our own cancel's ack — must be a no-op.
        let again = try await transport.receive()
        XCTAssertEqual(again, Data(), "post-close receive stays empty; cancelled did not become an error")
    }

    /// `.cancelled` racing a local close has one deterministic winner: close records `.closed`
    /// first, so the trailing `.cancelled` never overwrites the empty-Data result.
    func testCancelledRacingLocalCloseHasCloseAsWinner() async throws {
        let (transport, driver) = try await connectedTransport()
        await transport.close() // local close wins under the lock.
        driver.emit(.cancelled) // racing event — must not overwrite.
        let data = try await transport.receive()
        XCTAssertEqual(data, Data(), "recorded local-close result is never overwritten")
    }

    /// Unsolicited post-ready `.failed` is abnormal loss: a parked `receive()` throws the mapped
    /// `POSIXError`.
    func testUnsolicitedPostReadyFailedIsAbnormalLoss() async throws {
        let (transport, driver) = try await connectedTransport()
        async let parked = transport.receive()
        try? await Task.sleep(nanoseconds: 5_000_000)
        driver.emit(.failed(POSIXError(.ENETRESET)))
        do {
            _ = try await parked
            XCTFail("abnormal loss must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ENETRESET)
        }
    }

    /// Unsolicited post-ready `.cancelled` with no recorded local close is abnormal loss.
    func testUnsolicitedPostReadyCancelledIsAbnormalLoss() async throws {
        let (transport, driver) = try await connectedTransport()
        async let parked = transport.receive()
        try? await Task.sleep(nanoseconds: 5_000_000)
        driver.emit(.cancelled) // no local close recorded → abnormal.
        do {
            _ = try await parked
            XCTFail("unsolicited cancelled must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ECONNRESET)
        }
    }

    /// A receive-side error surfaces as abnormal loss through `receive()`.
    func testReceiveErrorSurfacesAsAbnormalLoss() async throws {
        let (transport, driver) = try await connectedTransport()
        async let parked = transport.receive()
        try? await Task.sleep(nanoseconds: 5_000_000)
        driver.deliver(.failure(POSIXError(.EIO)))
        do {
            _ = try await parked
            XCTFail("receive error must throw")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EIO)
        }
    }

    // MARK: - Helper: a transport driven to .ready

    private func connectedTransport() async throws -> (QUICTransportApple, ScriptedQUICDriver) {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)
        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.ready)
        try await task.value
        return (transport, driver)
    }
}

#endif // canImport(Network)
