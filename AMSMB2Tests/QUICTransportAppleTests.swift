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

/// A driver whose `start()` parks at entry — before its start side effect — until the test
/// releases it. This exposes the exact window after the transport has committed the claim toward
/// starting the driver but before the driver performs its start side effect, and records the
/// start/cancel event order so tests can prove "cancel happens exactly once, strictly after start".
///
/// The park never blocks a Swift cooperative thread: the transport invokes `start()` on its
/// dedicated (non-cooperative) start queue, so this wait occupies a GCD worker only. The wait is
/// **bounded** — if coordination breaks, a `"start-timeout"` event is recorded and `start()`
/// returns, so the test fails with a visible diagnostic instead of hanging the run.
final class GatedStartDriver: QUICConnectionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = TestFlag()
    private let release = DispatchSemaphore(value: 0)
    private var _events: [String] = []

    func start(
        onState _: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive _: @escaping @Sendable (Result<Data, POSIXError>) -> Void
    ) {
        entered.set()
        // Park before the start side effect; the test owns this window (bounded, see above).
        if release.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { _events.append("start-timeout") }
        }
        lock.withLock { _events.append("start") }
    }

    func cancel() {
        lock.withLock { _events.append("cancel") }
    }

    func send(_: Data) async throws {}

    // MARK: Test control

    func releaseStart() {
        release.signal() // signal() is async-safe (only wait() is not).
    }

    /// Appends a test-owned marker (e.g. `"close-returned"`) to the same ordered event stream,
    /// so caller-visible completions can be ordered against `start`/`cancel`.
    func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    var didEnterStart: Bool { entered.isSet }

    var events: [String] {
        lock.withLock { _events }
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

    /// Never-connected `receive()` → `ENOTCONN`: distinguishes "never connected" from
    /// "connected, then closed" (which returns empty `Data`).
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

    /// `send(_:)` on a never-connected transport → `ENOTCONN`. `ENOTCONN` is the transport's
    /// "no usable connection" error on the outbound direction, not a never-connected-only code.
    func testSendOnNeverConnectedThrowsENOTCONN() async {
        let driver = ScriptedQUICDriver()
        let transport = makeTransport(driver, ManualDeadlineScheduler())
        do {
            try await transport.send(Data([0x01]))
            XCTFail("never-connected send must throw ENOTCONN")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ENOTCONN)
        } catch {
            XCTFail("expected POSIXError(.ENOTCONN), got \(error)")
        }
        XCTAssertEqual(driver.sentChunks, [], "no bytes may reach a never-started driver")
    }

    /// `send(_:)` after a successful connect followed by `close()` → `ENOTCONN`.
    ///
    /// WHY this matters: the two directions are deliberately asymmetric after a local close.
    /// `receive()` returns empty `Data` because that empty `Data` *is* the teardown signal the
    /// `TransportBridge` inbound pump consumes; the outbound direction has no such convention, so
    /// a write with nowhere to go must surface as an error rather than silently succeeding. This
    /// mirrors `TCPTransportApple`, whose `close()` nils `_channel` so `send` hits the identical
    /// `ENOTCONN` guard — if this ever diverged, the two conformers would report different errors
    /// for the same post-teardown write.
    func testSendAfterCloseThrowsENOTCONN() async throws {
        let driver = ScriptedQUICDriver()
        let transport = makeTransport(driver, ManualDeadlineScheduler())

        let task = Task { try await transport.connect(host: "fs.example.com", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.ready)
        try await task.value

        await transport.close()

        do {
            try await transport.send(Data([0x01]))
            XCTFail("send after close must throw ENOTCONN, not succeed")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ENOTCONN)
        } catch {
            XCTFail("expected POSIXError(.ENOTCONN), got \(error)")
        }
        XCTAssertEqual(driver.sentChunks, [], "no bytes may reach the driver after close")
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
    /// driver (no `NWConnection` is created). Deterministic — and free of any parking — because
    /// the driver factory runs on the connect task itself, in exactly the window between
    /// `Task.checkCancellation()` and the continuation store: cancelling the current task there
    /// exercises the store's cancellation re-check at any executor width.
    func testCancellationBeforeStartThrowsAndNeverStartsDriver() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return driver
            },
            deadline: scheduler
        )

        let task = Task { try await transport.connect(host: "h", port: 443) }
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

    // MARK: Commit-to-start gap (P1 regression — the window AFTER the transport commits toward
    // `driver.start()` but BEFORE the driver's start side effect)

    private func makeGatedTransport(
        _ driver: GatedStartDriver, _ scheduler: ManualDeadlineScheduler
    ) -> QUICTransportApple {
        QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in driver },
            deadline: scheduler
        )
    }

    /// Regression (P1): `close()` that wins the claim in the commit-to-start gap must not cancel
    /// in that window (the starting path finishes the loss after `start()` returns) — **and must
    /// not complete** until that teardown has run: `SMBTransport.close()` promises resources are
    /// released when it returns, so the parked committed start (and its cancel) may never fire
    /// after `close()` has returned. Proven by ordering `close-returned` in the same
    /// event stream as `start`/`cancel`.
    func testCloseInCommitToStartGapWaitsForTeardownAndCancelsAfterStartOnce() async {
        let driver = GatedStartDriver()
        let transport = makeGatedTransport(driver, ManualDeadlineScheduler())

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didEnterStart }, "transport committed toward start")

        let closeDone = TestFlag()
        let closeTask = Task {
            await transport.close() // loser in the gap; must park until the handoff tears down.
            driver.record("close-returned")
            closeDone.set()
        }
        await waitUntil(
            { transport.pendingCloseWaiterCount == 1 }, "close parked awaiting teardown"
        )
        XCTAssertFalse(
            closeDone.isSet, "close() must not complete while the committed start is still gated"
        )
        XCTAssertEqual(driver.events, [], "no cancel may precede the driver's start side effect")

        driver.releaseStart()
        do {
            try await task.value
            XCTFail("close in the commit-to-start gap must fail the connect")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ECONNABORTED)
        } catch {
            XCTFail("expected POSIXError(.ECONNABORTED), got \(error)")
        }
        await closeTask.value
        // All tasks are joined and the transport holds no further path to the driver, so this
        // final snapshot is exhaustive: start happened exactly once, cancel exactly once and
        // strictly after start, and close() returned only after the cancel.
        XCTAssertEqual(
            driver.events, ["start", "cancel", "close-returned"],
            "close() may return only after the committed start was performed and cancelled"
        )
    }

    /// Regression (P1): two concurrent `close()` callers racing the same commit-to-start gap
    /// must BOTH wait for the same teardown, and the teardown still cancels exactly once.
    func testConcurrentClosesInCommitToStartGapBothWaitForTeardownOneCancel() async {
        let driver = GatedStartDriver()
        let transport = makeGatedTransport(driver, ManualDeadlineScheduler())

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didEnterStart }, "transport committed toward start")

        let firstDone = TestFlag()
        let secondDone = TestFlag()
        let firstClose = Task {
            await transport.close()
            firstDone.set()
        }
        let secondClose = Task {
            await transport.close()
            secondDone.set()
        }
        await waitUntil(
            { transport.pendingCloseWaiterCount == 2 }, "both close callers parked"
        )
        XCTAssertFalse(firstDone.isSet, "first close must wait for the pending teardown")
        XCTAssertFalse(secondDone.isSet, "second close must wait for the same pending teardown")
        XCTAssertEqual(driver.events, [], "no cancel may precede the driver's start side effect")

        driver.releaseStart()
        do {
            try await task.value
            XCTFail("close in the commit-to-start gap must fail the connect")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ECONNABORTED, "connect aborts exactly once with ECONNABORTED")
        } catch {
            XCTFail("expected POSIXError(.ECONNABORTED), got \(error)")
        }
        await firstClose.value
        await secondClose.value
        XCTAssertEqual(
            driver.events, ["start", "cancel"],
            "one teardown serves both close callers: exactly one cancel, after start"
        )
    }

    /// Regression (P1): when task cancellation (not close) parked the loss in the gap, a
    /// subsequent `close()` must still wait for the committed start's teardown — otherwise the
    /// driver would start after `close()` returned even though close never owned the claim.
    func testCloseAfterCancelParkedLossWaitsForTeardown() async {
        let driver = GatedStartDriver()
        let transport = makeGatedTransport(driver, ManualDeadlineScheduler())

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didEnterStart }, "transport committed toward start")
        task.cancel() // parks the loss in the gap; teardown is now pending.

        let closeDone = TestFlag()
        let closeTask = Task {
            await transport.close()
            driver.record("close-returned")
            closeDone.set()
        }
        await waitUntil(
            { transport.pendingCloseWaiterCount == 1 }, "close parked behind the cancel's teardown"
        )
        XCTAssertFalse(closeDone.isSet, "close must wait even when another loser parked the loss")
        XCTAssertEqual(driver.events, [], "no cancel may precede the driver's start side effect")

        driver.releaseStart()
        do {
            try await task.value
            XCTFail("cancellation in the commit-to-start gap must fail the connect")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        await closeTask.value
        XCTAssertEqual(
            driver.events, ["start", "cancel", "close-returned"],
            "close() returns only after the committed start was performed and cancelled"
        )
    }

    /// Regression (P1): task cancellation winning in the commit-to-start gap — same contract as
    /// the close-in-gap case, surfacing `CancellationError`.
    func testTaskCancelInCommitToStartGapCancelsAfterStartExactlyOnce() async {
        let driver = GatedStartDriver()
        let transport = makeGatedTransport(driver, ManualDeadlineScheduler())

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didEnterStart }, "transport committed toward start")
        task.cancel() // loser in the gap.
        XCTAssertEqual(driver.events, [], "no cancel may precede the driver's start side effect")

        driver.releaseStart()
        do {
            try await task.value
            XCTFail("cancellation in the commit-to-start gap must fail the connect")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(
            driver.events, ["start", "cancel"],
            "start committed first → started driver cancelled exactly once, after start"
        )
    }

    /// Regression (P1): deadline expiry winning in the commit-to-start gap — same contract,
    /// surfacing `POSIXError(.ETIMEDOUT)`.
    func testDeadlineInCommitToStartGapCancelsAfterStartExactlyOnce() async {
        let driver = GatedStartDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeGatedTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didEnterStart }, "transport committed toward start")
        scheduler.fireNow() // loser in the gap.
        XCTAssertEqual(driver.events, [], "no cancel may precede the driver's start side effect")

        driver.releaseStart()
        do {
            try await task.value
            XCTFail("deadline in the commit-to-start gap must fail the connect")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ETIMEDOUT)
        } catch {
            XCTFail("expected POSIXError(.ETIMEDOUT), got \(error)")
        }
        XCTAssertEqual(
            driver.events, ["start", "cancel"],
            "start committed first → started driver cancelled exactly once, after start"
        )
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

// MARK: - Public initializer timeout validation (P2 regression)

/// The public production path must enforce the same connect-timeout contract as
/// `SMB2Client.connect` (design D10): a directly constructed `QUICTransportApple` can never hold
/// an invalid, unnormalized deadline. The timeout's single source of truth is
/// `SMBQUICConfiguration.connectTimeout`.
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
final class QUICTransportApplePublicInitTests: XCTestCase {
    func testInvalidConnectTimeoutsThrowEINVALFromPublicInit() {
        let invalid: [TimeInterval] = [.nan, .infinity, -.infinity, 0, -1, -30.5]
        for value in invalid {
            XCTAssertThrowsError(
                try QUICTransportApple(configuration: SMBQUICConfiguration(connectTimeout: value)),
                "connectTimeout \(value) must be rejected before any NWConnection exists"
            ) { error in
                XCTAssertEqual(
                    (error as? POSIXError)?.code, .EINVAL, "connectTimeout \(value) → EINVAL"
                )
            }
        }
    }

    func testValidConnectTimeoutsNormalizeThroughPublicInit() throws {
        XCTAssertEqual(
            try QUICTransportApple(
                configuration: SMBQUICConfiguration(connectTimeout: 7200)).connectTimeout,
            3600, "values above 3600 clamp to 3600"
        )
        XCTAssertEqual(
            try QUICTransportApple(
                configuration: SMBQUICConfiguration(connectTimeout: 3600)).connectTimeout,
            3600, "3600 itself passes unclamped"
        )
        XCTAssertEqual(
            try QUICTransportApple(
                configuration: SMBQUICConfiguration(connectTimeout: 0.25)).connectTimeout,
            0.25, "sub-second values are honored as-is"
        )
        XCTAssertEqual(
            try QUICTransportApple(configuration: SMBQUICConfiguration()).connectTimeout,
            30, "the default deadline is 30 s"
        )
    }

    /// The public production path (real driver factory, real deadline scheduler): an
    /// out-of-range port surfaces as `POSIXError(.EINVAL)` from `connect` — the invalid-port
    /// driver emits `.failed` without ever creating an `NWConnection`.
    func testPublicTransportConnectRejectsOutOfRangePort() async throws {
        let transport = try QUICTransportApple(configuration: SMBQUICConfiguration())
        do {
            try await transport.connect(host: "fs.example.com", port: 65536)
            XCTFail("out-of-range port must throw EINVAL")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EINVAL)
        } catch {
            XCTFail("expected POSIXError(.EINVAL), got \(error)")
        }
    }
}

// MARK: - NWConnectionQUICDriver port validation (P2 regression)

/// Boundary tests for the production driver's port handling: only 1...65535 is accepted;
/// out-of-range ports (0, negative, > 65535) must produce `POSIXError(.EINVAL)` and create NO
/// `NWConnection` — in particular 65536 must never silently become UDP/0. Constructing (without
/// starting) an `NWConnection` is inert, so the accepted-boundary checks touch no network.
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
final class NWConnectionQUICDriverPortTests: XCTestCase {
    func testOutOfRangePortsAreRejectedWithEINVALAndNoConnection() {
        for port in [0, -1, 65536, 1 << 20] {
            let driver = NWConnectionQUICDriver(host: "fs.example.com", port: port, trust: .system)
            XCTAssertNil(driver.connection, "port \(port): no NWConnection may be created")
            XCTAssertEqual(driver.initError?.code, .EINVAL, "port \(port): must fail with EINVAL")
        }
    }

    func testBoundaryPortsAreAcceptedAndPreserved() throws {
        for port in [1, 65535] {
            let driver = NWConnectionQUICDriver(host: "fs.example.com", port: port, trust: .system)
            XCTAssertNil(driver.initError, "port \(port): valid boundary port must be accepted")
            let connection = try XCTUnwrap(driver.connection, "port \(port): connection must exist")
            guard case .hostPort(_, let nwPort) = connection.endpoint else {
                XCTFail("port \(port): expected a hostPort endpoint, got \(connection.endpoint)")
                continue
            }
            XCTAssertEqual(Int(nwPort.rawValue), port, "the valid explicit port is preserved unchanged")
        }
    }
}

#endif // canImport(Network)
