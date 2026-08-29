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
import Network
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
    private var _onCancel: (@Sendable () -> Void)?

    /// Optional hook fired from `cancel()` (outside the lock), after the cancel is counted. Lets a
    /// test observe teardown ordering — the certificate probe uses it to store into its capture
    /// slot strictly during `close()`. Unset by default, so every other test is unaffected.
    var onCancel: (@Sendable () -> Void)? {
        get { lock.withLock { _onCancel } }
        set { lock.withLock { _onCancel = newValue } }
    }

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
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            _cancelCount += 1
            return _onCancel
        }
        hook?()
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
    private var onState: (@Sendable (QUICConnectionState) -> Void)?

    func start(
        onState: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive _: @escaping @Sendable (Result<Data, POSIXError>) -> Void
    ) {
        lock.withLock { self.onState = onState }
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

    /// Emits a state through the handler captured at `start()` entry (available even while the
    /// start is still gated), so a gated connect can be driven to `.ready` after release.
    func emit(_ state: QUICConnectionState) {
        let handler = lock.withLock { onState }
        handler?(state)
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

/// A minimal lock-guarded mutable box for values shared between test closures and assertions.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        self._value = value
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&_value) }
    }

    var value: Value {
        lock.withLock { _value }
    }
}

/// Records the terminal outcome of an async call (success or the thrown error) so tests can
/// bound-wait on completion and inspect the error without awaiting a task that might hang.
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: (any Error)?
    private var _completed = false

    func complete(with error: (any Error)?) {
        lock.withLock {
            _error = error
            _completed = true
        }
    }

    var isCompleted: Bool {
        lock.withLock { _completed }
    }

    var error: (any Error)? {
        lock.withLock { _error }
    }
}

/// A driver whose `cancel()` parks (bounded) until released — holds an ordinary established
/// teardown open deterministically so a test can prove concurrent `close()` callers wait for
/// completed teardown. The park occupies a GCD worker only (the transport performs close-owned
/// cancellation on its dedicated teardown queue, never a Swift cooperative thread); the wait is
/// **bounded** — on breakage a `"cancel-timeout"` event is recorded and `cancel()` returns, so
/// a regression fails with a visible diagnostic instead of hanging the suite.
final class GatedCancelDriver: QUICConnectionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var _events: [String] = []
    private var onState: (@Sendable (QUICConnectionState) -> Void)?

    func start(
        onState: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive _: @escaping @Sendable (Result<Data, POSIXError>) -> Void
    ) {
        lock.withLock {
            self.onState = onState
            _events.append("start")
        }
    }

    func cancel() {
        if release.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { _events.append("cancel-timeout") }
        }
        lock.withLock { _events.append("cancel") }
    }

    func send(_: Data) async throws {}

    // MARK: Test control

    func emit(_ state: QUICConnectionState) {
        let handler = lock.withLock { onState }
        handler?(state)
    }

    func releaseCancel() {
        release.signal()
    }

    func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    var events: [String] {
        lock.withLock { _events }
    }
}

/// A driver that emits `.ready` from **inside** `start()` and then parks (bounded) before
/// returning — the ready-mid-start shape: the connect succeeds while the tail of `start()` is
/// still executing. Tests use it to prove `close()` cancels the ready driver immediately but
/// does not return until the in-flight `start()` tail has finished. Bounded like the other
/// gated doubles; the park sits on the transport's dedicated start queue (a GCD worker).
final class ReadyMidStartDriver: QUICConnectionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var _events: [String] = []

    func start(
        onState: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive _: @escaping @Sendable (Result<Data, POSIXError>) -> Void
    ) {
        lock.withLock { _events.append("start-entered") }
        onState(.ready) // .ready wins while start() is still executing.
        if release.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { _events.append("start-timeout") }
        }
        lock.withLock { _events.append("start-returned") }
    }

    func cancel() {
        lock.withLock { _events.append("cancel") }
    }

    func send(_: Data) async throws {}

    // MARK: Test control

    func releaseStart() {
        release.signal()
    }

    func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    var events: [String] {
        lock.withLock { _events }
    }
}

/// A scheduler that parks inside `schedule()` (bounded) after signalling entry, then records
/// the timer as armed and returns — modelling a real scheduler whose arm-and-record loses the
/// store-to-schedule race against a loser's early `cancel()`. `schedule()` runs on the
/// transport's dedicated start queue, so the park never blocks a cooperative thread.
final class GatedArmingScheduler: ConnectDeadlineScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = TestFlag()
    private let release = DispatchSemaphore(value: 0)
    private var _armed = false
    private var _cancelCount = 0
    private var _timedOut = false

    func schedule(after _: TimeInterval, fire _: @escaping @Sendable () -> Void) {
        entered.set()
        if release.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { _timedOut = true }
        }
        lock.withLock { _armed = true } // the timer arms late, after any early cancel().
    }

    func cancel() {
        lock.withLock {
            _armed = false
            _cancelCount += 1
        }
    }

    // MARK: Test control

    func releaseSchedule() {
        release.signal()
    }

    var didEnterSchedule: Bool { entered.isSet }

    var isArmed: Bool {
        lock.withLock { _armed }
    }

    var scheduleTimedOut: Bool {
        lock.withLock { _timedOut }
    }

    var cancelCount: Int {
        lock.withLock { _cancelCount }
    }
}

/// A scheduler whose `schedule()` synchronously fires the loss callback FIRST — so the loss
/// path's `cancel()` runs while no timer is recorded — and only then records itself as armed
/// (the exact finding-3 store-to-schedule race). The transport's post-schedule claim re-check
/// must notice the consumed claim and cancel the late-armed timer.
final class SelfFiringArmingScheduler: ConnectDeadlineScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var _armed = false
    private var _cancelCount = 0

    func schedule(after _: TimeInterval, fire: @escaping @Sendable () -> Void) {
        fire() // the loss resolves (and cancels) before any timer exists…
        lock.withLock { _armed = true } // …then the timer arms late.
    }

    func cancel() {
        lock.withLock {
            _armed = false
            _cancelCount += 1
        }
    }

    var isArmed: Bool {
        lock.withLock { _armed }
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

    /// Spec "Transient waiting is non-terminal": a transient `.waiting` must neither fail the
    /// connect nor disarm the deadline — only cancellation, `close()`, or the deadline itself
    /// ends a wait. WHY: classifying `.waiting` (this change) must not regress the transient
    /// class into the new fail-fast path; the still-armed deadline is what bounds a stuck wait.
    func testWaitingIsNonTerminalThenReadySucceeds() async throws {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.setup)
        driver.emit(.preparing)
        driver.emit(.waiting(POSIXError(.ENETDOWN), .transient))
        XCTAssertEqual(
            scheduler.cancelCount, 0, "a transient wait leaves the connect deadline armed"
        )
        XCTAssertEqual(driver.cancelCount, 0, "a transient wait claims nothing and cancels nothing")

        driver.emit(.ready)
        try await task.value // did not fail on .waiting.
        XCTAssertEqual(scheduler.cancelCount, 1, "the winning .ready cancels the deadline once")
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

    /// Spec "Fatal waiting fails fast": a fatal `.waiting` (a TLS handshake/trust rejection)
    /// claims the connect outcome as failure through the same atomic claim as `.failed`.
    /// WHY: a trust rejection is deterministic — waiting it out to `connectTimeout` is pure
    /// latency and reports `ETIMEDOUT`, making an untrusted certificate indistinguishable from
    /// an unreachable server. The deadline must be cancelled (not awaited), the started driver
    /// cancelled exactly once, and the continuation resumed exactly once.
    func testFatalWaitingFailsFastWithMappedError() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler)

        let (task, outcome) = launchConnect(transport)
        await waitUntil({ driver.didStart }, "driver started")
        driver.emit(.waiting(POSIXError(.EPROTO), .fatal))

        await expectPromptPOSIX(outcome, .EPROTO, "fatal waiting")
        XCTAssertEqual(scheduler.cancelCount, 1, "the deadline is cancelled exactly once, never awaited")
        XCTAssertEqual(driver.cancelCount, 1, "the started driver is cancelled exactly once")

        // Late events on a finished attempt are no-ops: no second cancel, no second resume.
        driver.emit(.failed(POSIXError(.ECONNRESET)))
        task.cancel()
        await reap(task, ifCompleted: outcome.isCompleted)
        XCTAssertEqual(driver.cancelCount, 1, "no second cancel from post-claim events")
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
        driver.emit(.waiting(POSIXError(.ETIMEDOUT), .transient)) // driver holds .waiting.
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

    /// Spec "Fatal waiting in the commit-to-start window is a parked loss": a fatal `.waiting`
    /// delivered after the transport committed toward `start()` but before the start side effect
    /// must behave exactly like a `.failed` in that window. WHY: routing fatal waits through
    /// `handleFailed` (design D2) is only safe if it inherits the parked-loss handoff —
    /// cancelling inside the window would cancel a driver before its start side effect.
    func testFatalWaitingInCommitToStartGapCancelsAfterStartExactlyOnce() async {
        let driver = GatedStartDriver()
        let transport = makeGatedTransport(driver, ManualDeadlineScheduler())

        let task = Task { try await transport.connect(host: "h", port: 443) }
        await waitUntil({ driver.didEnterStart }, "transport committed toward start")
        driver.emit(.waiting(POSIXError(.EPROTO), .fatal)) // loser parked inside the window.
        XCTAssertEqual(driver.events, [], "no cancel may precede the driver's start side effect")

        driver.releaseStart()
        do {
            try await task.value
            XCTFail("a fatal wait in the commit-to-start gap must fail the connect")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EPROTO)
        } catch {
            XCTFail("expected POSIXError(.EPROTO), got \(error)")
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
        driver.emit(.waiting(POSIXError(.EHOSTUNREACH), .transient))
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

    /// Spec "Deadline expiry" + "No double resume": a fatal `.waiting` that arrives after the
    /// deadline has already claimed the outcome is a side-effect-free no-op — the `ETIMEDOUT`
    /// stands, the driver is not cancelled a second time, and the continuation is not resumed
    /// again. WHY: fatal waits now claim the outcome, so they must still lose cleanly to a claim
    /// already consumed by the deadline (Network.framework re-emits `.waiting(.tls)`). The
    /// load-bearing check is implicit: a second resume would trap in `CheckedContinuation` and
    /// crash the run — the explicit assertions guard the single cancel and the standing
    /// `ETIMEDOUT`.
    func testFatalWaitingAfterDeadlineIsNoOp() async {
        let driver = ScriptedQUICDriver()
        let scheduler = ManualDeadlineScheduler()
        let transport = makeTransport(driver, scheduler, connectTimeout: 12)

        let (task, outcome) = launchConnect(transport)
        await waitUntil({ driver.didStart }, "driver started")
        scheduler.fireNow()
        await expectPromptPOSIX(outcome, .ETIMEDOUT, "deadline expiry")
        XCTAssertEqual(driver.cancelCount, 1, "the deadline cancels the connection once")

        driver.emit(.waiting(POSIXError(.EPROTO, description: "QUIC TLS error: -9808"), .fatal))
        await reap(task, ifCompleted: outcome.isCompleted)
        XCTAssertEqual(
            (outcome.error as? POSIXError)?.code, .ETIMEDOUT, "the deadline's outcome stands"
        )
        XCTAssertEqual(driver.cancelCount, 1, "the losing fatal wait performs no side effect")
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

    /// Spec "Fatal waiting fails fast" (second bullet): a fatal `.waiting` landing after `.ready`
    /// won the claim never re-enters connect completion — it is routed like any post-ready
    /// `.failed`, i.e. abnormal transport loss delivered to a parked `receive()` (design D8).
    /// WHY: re-entering connect completion would resume an already-consumed continuation (a
    /// trap); silently ignoring it would leave a session whose TLS layer reported failure looking
    /// healthy until the next I/O hung.
    func testPostReadyFatalWaitingIsAbnormalLoss() async throws {
        let (transport, driver) = try await connectedTransport()
        async let parked = transport.receive()
        try? await Task.sleep(nanoseconds: 5_000_000)
        driver.emit(.waiting(POSIXError(.EPROTO), .fatal))
        do {
            _ = try await parked
            XCTFail("post-ready fatal waiting must surface as abnormal loss")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .EPROTO)
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

    // MARK: - Helpers: bounded connect/close probes (no unbounded awaits on possibly-hung tasks)

    /// Runs `connect` in a child task, capturing the terminal outcome in an `ErrorBox`.
    /// Tests bound-wait on `outcome.isCompleted` instead of awaiting a task that a regression
    /// could leave suspended forever.
    private func launchConnect(
        _ transport: QUICTransportApple, host: String = "h", port: Int = 443
    ) -> (task: Task<Void, Never>, outcome: ErrorBox) {
        let outcome = ErrorBox()
        let task = Task {
            do {
                try await transport.connect(host: host, port: port)
                outcome.complete(with: nil)
            } catch {
                outcome.complete(with: error)
            }
        }
        return (task, outcome)
    }

    /// Runs `close()` in a child task; `marker` runs after close returns (before the flag).
    private func launchClose(
        _ transport: QUICTransportApple, marker: (@Sendable () -> Void)? = nil
    ) -> (task: Task<Void, Never>, done: TestFlag) {
        let done = TestFlag()
        let task = Task {
            await transport.close()
            marker?()
            done.set()
        }
        return (task, done)
    }

    /// Joins `task` only when `completed` is true; otherwise cancels and abandons it — the
    /// bounded wait that produced `completed == false` has already failed the test with a
    /// diagnostic, and awaiting a task a regression left suspended would hang the suite.
    private func reap(_ task: Task<Void, Never>, ifCompleted completed: Bool) async {
        if completed {
            await task.value
        } else {
            task.cancel()
        }
    }

    /// Bound-waits for `outcome` to complete, then asserts it failed with the given POSIX code.
    private func expectPromptPOSIX(
        _ outcome: ErrorBox, _ code: POSIXError.Code, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        await waitUntil({ outcome.isCompleted }, "\(label) must complete promptly", file: file, line: line)
        guard outcome.isCompleted else { return } // waitUntil already failed with a diagnostic.
        guard let posix = outcome.error as? POSIXError else {
            XCTFail(
                "\(label): expected POSIXError(.\(code.rawValue)), got \(String(describing: outcome.error))",
                file: file, line: line
            )
            return
        }
        XCTAssertEqual(posix.code, code, label, file: file, line: line)
    }

    // MARK: - One-shot connect ownership (P1)

    /// Two concurrent `connect` calls: the first owns the single attempt; the second fails
    /// promptly with `EALREADY` without constructing a driver, and the first completes
    /// unaffected. WHY: `QUICTransportApple` is public and documented as one instance per
    /// connection lifetime — without an atomic reservation a second call would overwrite the
    /// first continuation and driver, suspending the first caller forever.
    func testConcurrentSecondConnectFailsEALREADYAndFirstCompletes() async throws {
        let drivers = LockedBox<[ScriptedQUICDriver]>([])
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in
                let driver = ScriptedQUICDriver()
                drivers.mutate { $0.append(driver) }
                return driver
            },
            deadline: ManualDeadlineScheduler()
        )

        let (firstTask, first) = launchConnect(transport)
        await waitUntil({ drivers.value.first?.didStart == true }, "first driver started")

        let (secondTask, second) = launchConnect(transport)
        await expectPromptPOSIX(second, .EALREADY, "second concurrent connect")
        XCTAssertEqual(drivers.value.count, 1, "the rejected call must not construct a driver")

        drivers.value.first?.emit(.ready)
        await waitUntil({ first.isCompleted }, "first connect completes")
        if first.isCompleted {
            XCTAssertNil(first.error, "the owning connect must succeed unaffected")
        }
        XCTAssertEqual(drivers.value.first?.cancelCount, 0, "no cancel on the owning attempt")
        await reap(firstTask, ifCompleted: first.isCompleted)
        await reap(secondTask, ifCompleted: second.isCompleted)
    }

    /// `connect` after `.ready` fails promptly with `EISCONN`; the established driver remains
    /// installed and usable (no replacement, no leak, no start of a second driver).
    func testConnectAfterReadyFailsEISCONNAndKeepsDriverUsable() async throws {
        let drivers = LockedBox<[ScriptedQUICDriver]>([])
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in
                let driver = ScriptedQUICDriver()
                drivers.mutate { $0.append(driver) }
                return driver
            },
            deadline: ManualDeadlineScheduler()
        )
        let (firstTask, first) = launchConnect(transport)
        await waitUntil({ drivers.value.first?.didStart == true }, "driver started")
        drivers.value.first?.emit(.ready)
        await waitUntil({ first.isCompleted }, "first connect completes")
        await reap(firstTask, ifCompleted: first.isCompleted)

        let (secondTask, second) = launchConnect(transport)
        await expectPromptPOSIX(second, .EISCONN, "connect after ready")
        await reap(secondTask, ifCompleted: second.isCompleted)
        XCTAssertEqual(drivers.value.count, 1, "the rejected call must not construct a driver")

        try await transport.send(Data([0x0a]))
        XCTAssertEqual(
            drivers.value.first?.sentChunks, [Data([0x0a])],
            "the original established driver remains installed and usable"
        )
    }

    /// `connect` while the first attempt sits in the commit-to-start gap fails with `EALREADY`
    /// and cannot overwrite the first attempt's continuation or driver: after the gate is
    /// released the first attempt still completes with its own driver, started exactly once.
    func testSecondConnectInCommitToStartGapFailsEALREADYAndCannotOverwrite() async throws {
        let driver = GatedStartDriver()
        let factoryCalls = LockedBox<Int>(0)
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in
                factoryCalls.mutate { $0 += 1 }
                return driver
            },
            deadline: ManualDeadlineScheduler()
        )

        let (firstTask, first) = launchConnect(transport)
        await waitUntil({ driver.didEnterStart }, "first attempt committed toward start")

        let (secondTask, second) = launchConnect(transport)
        await expectPromptPOSIX(second, .EALREADY, "connect during the commit-to-start gap")
        await reap(secondTask, ifCompleted: second.isCompleted)
        XCTAssertEqual(factoryCalls.value, 1, "the rejected call must not construct a driver")

        driver.releaseStart()
        driver.emit(.ready)
        await waitUntil({ first.isCompleted }, "first connect completes after release")
        if first.isCompleted {
            XCTAssertNil(first.error, "the owning attempt still completes with its own driver")
        }
        await reap(firstTask, ifCompleted: first.isCompleted)
        XCTAssertEqual(
            driver.events, ["start"],
            "exactly one driver start; the rejected call started nothing and cancelled nothing"
        )
    }

    /// `connect` after `close()` preserves the closed-transport contract (`ECONNABORTED`) and
    /// performs no work at all: the driver factory is never invoked.
    func testConnectAfterCloseFailsECONNABORTEDWithoutCreatingDriver() async {
        let factoryCalls = LockedBox<Int>(0)
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in
                factoryCalls.mutate { $0 += 1 }
                return ScriptedQUICDriver()
            },
            deadline: ManualDeadlineScheduler()
        )
        await transport.close()

        let (task, outcome) = launchConnect(transport)
        await expectPromptPOSIX(outcome, .ECONNABORTED, "connect after close")
        await reap(task, ifCompleted: outcome.isCompleted)
        XCTAssertEqual(factoryCalls.value, 0, "a rejected connect must not create a driver")
    }

    /// Retry after a failed first attempt is NOT supported: the transport is strictly one-shot
    /// (one instance per connection lifetime; SMB2Client builds a fresh transport per connect).
    /// A second call after failure fails promptly with `EALREADY` and constructs nothing.
    func testConnectAfterFailedAttemptFailsEALREADYNoRetry() async {
        let drivers = LockedBox<[ScriptedQUICDriver]>([])
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in
                let driver = ScriptedQUICDriver()
                drivers.mutate { $0.append(driver) }
                return driver
            },
            deadline: ManualDeadlineScheduler()
        )
        let (firstTask, first) = launchConnect(transport)
        await waitUntil({ drivers.value.first?.didStart == true }, "driver started")
        drivers.value.first?.emit(.failed(POSIXError(.ECONNREFUSED)))
        await waitUntil({ first.isCompleted }, "first connect fails")
        if first.isCompleted {
            XCTAssertEqual((first.error as? POSIXError)?.code, .ECONNREFUSED)
        }
        await reap(firstTask, ifCompleted: first.isCompleted)

        let (secondTask, second) = launchConnect(transport)
        await expectPromptPOSIX(second, .EALREADY, "connect after a failed attempt")
        await reap(secondTask, ifCompleted: second.isCompleted)
        XCTAssertEqual(drivers.value.count, 1, "no second driver is ever constructed")
        XCTAssertEqual(drivers.value.first?.cancelCount, 1, "first attempt torn down exactly once")
    }

    // MARK: - Close lifecycle: every concurrent close waits for completed teardown (P1)

    /// Ordinary established teardown held open: the second concurrent `close()` must NOT return
    /// before the first caller's teardown (driver cancellation) has completed. WHY:
    /// `SMBTransport.close()` promises all resources are released when it returns — for every
    /// caller, not only the teardown owner.
    func testConcurrentCloseDuringEstablishedTeardownWaitsForCompletedTeardown() async throws {
        let driver = GatedCancelDriver()
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in driver },
            deadline: ManualDeadlineScheduler()
        )
        let (connectTask, connectOutcome) = launchConnect(transport)
        await waitUntil({ driver.events.contains("start") }, "driver started")
        driver.emit(.ready)
        await waitUntil({ connectOutcome.isCompleted }, "connect completes")
        XCTAssertNil(connectOutcome.error)
        await reap(connectTask, ifCompleted: connectOutcome.isCompleted)

        let (close1, done1) = launchClose(transport, marker: { driver.record("close-a-returned") })
        let (close2, done2) = launchClose(transport, marker: { driver.record("close-b-returned") })
        await waitUntil(
            { transport.pendingCloseWaiterCount == 1 },
            "the non-owning close caller parks until the owner's teardown completes"
        )
        XCTAssertFalse(done1.isSet, "the owning close must not return while cancel() is gated")
        XCTAssertFalse(done2.isSet, "the concurrent close must not return before teardown completes")
        XCTAssertEqual(driver.events, ["start"], "cancel has not completed yet — closes must wait")

        driver.releaseCancel()
        await waitUntil({ done1.isSet && done2.isSet }, "both closes return after teardown")
        await reap(close1, ifCompleted: done1.isSet)
        await reap(close2, ifCompleted: done2.isSet)
        let events = driver.events
        XCTAssertEqual(
            Array(events.prefix(2)), ["start", "cancel"],
            "exactly one cancel, completed before any close returns"
        )
        XCTAssertEqual(
            Set(events.dropFirst(2)), ["close-a-returned", "close-b-returned"],
            "both close callers return only after the completed teardown"
        )
        XCTAssertEqual(events.filter { $0 == "cancel" }.count, 1, "exactly one cancel")
    }

    /// Pre-commit connect abort with two concurrent closes: both close callers wait for the
    /// full connect-attempt tail (including the late-arming deadline), the connect resolves
    /// exactly once with `ECONNABORTED`, the driver never starts, and no timer stays armed
    /// after close returns.
    func testConcurrentClosesDuringPreCommitAbortWaitAndCancelLateArmedDeadline() async {
        let scheduler = GatedArmingScheduler()
        let driver = ScriptedQUICDriver()
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in driver },
            deadline: scheduler
        )
        let (connectTask, connectOutcome) = launchConnect(transport)
        await waitUntil({ scheduler.didEnterSchedule }, "attempt parked inside schedule() — pre-commit")

        let (close1, done1) = launchClose(transport)
        let (close2, done2) = launchClose(transport)
        await expectPromptPOSIX(connectOutcome, .ECONNABORTED, "pre-commit abort by close")
        await waitUntil(
            { transport.pendingCloseWaiterCount == 2 },
            "both close callers park until the connect-attempt tail finishes"
        )
        XCTAssertFalse(done1.isSet, "owner close must wait for the attempt tail")
        XCTAssertFalse(done2.isSet, "concurrent close must wait for the same tail")

        scheduler.releaseSchedule()
        await waitUntil({ done1.isSet && done2.isSet }, "both closes return after the tail finishes")
        await reap(close1, ifCompleted: done1.isSet)
        await reap(close2, ifCompleted: done2.isSet)
        await reap(connectTask, ifCompleted: connectOutcome.isCompleted)
        XCTAssertFalse(scheduler.isArmed, "no timer may remain armed after close() returned")
        XCTAssertFalse(driver.didStart, "pre-commit abort suppresses the start")
        XCTAssertEqual(driver.cancelCount, 0, "nothing was started → nothing is cancelled")
        XCTAssertFalse(scheduler.scheduleTimedOut, "test coordination stayed within bounds")
    }

    /// A `close()` made after a prior close fully completed returns promptly and performs no
    /// second teardown (the terminal no-op case — distinct from a concurrent close, which waits).
    func testCloseAfterCompletedCloseIsPromptNoOpWithoutSecondTeardown() async throws {
        let (transport, driver) = try await connectedTransport()
        await transport.close()
        XCTAssertEqual(driver.cancelCount, 1, "first close performs the single teardown")
        await transport.close() // after full completion — must be a prompt no-op.
        XCTAssertEqual(driver.cancelCount, 1, "no second teardown")
    }

    // MARK: - Late-armed deadline is cancelled after an earlier loss (P2)

    /// The finding-3 race in its purest shape: `schedule()` fires the loss synchronously before
    /// recording the timer, the loss path's `cancel()` finds no timer, then the timer arms late.
    /// The post-schedule claim re-check must cancel it; the continuation resolves exactly once.
    func testDeadlineSelfFireBeforeArmIsCancelledAfterLoss() async {
        let scheduler = SelfFiringArmingScheduler()
        let driver = ScriptedQUICDriver()
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 5,
            driverFactory: { _, _, _ in driver },
            deadline: scheduler
        )
        let (task, outcome) = launchConnect(transport)
        await expectPromptPOSIX(outcome, .ETIMEDOUT, "self-firing deadline")
        await reap(task, ifCompleted: outcome.isCompleted)
        await waitUntil({ !scheduler.isArmed }, "late-armed timer is cancelled by the claim re-check")
        XCTAssertFalse(scheduler.isArmed, "final scheduler state must be unarmed")
        XCTAssertFalse(driver.didStart, "consumed claim suppresses the start")
        XCTAssertEqual(driver.cancelCount, 0, "nothing started → nothing cancelled")
    }

    /// Task cancellation winning while the timer is still arming: the loss cancels a not-yet
    /// recorded timer; once `schedule()` finally arms, the post-schedule re-check cancels it.
    func testTaskCancellationDuringScheduleCancelsLateArmedTimer() async {
        let scheduler = GatedArmingScheduler()
        let driver = ScriptedQUICDriver()
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in driver },
            deadline: scheduler
        )
        let (task, outcome) = launchConnect(transport)
        await waitUntil({ scheduler.didEnterSchedule }, "attempt parked inside schedule()")
        task.cancel()
        await waitUntil({ outcome.isCompleted }, "cancellation resolves the connect")
        if outcome.isCompleted {
            XCTAssertTrue(
                outcome.error is CancellationError,
                "expected CancellationError, got \(String(describing: outcome.error))"
            )
        }
        await reap(task, ifCompleted: outcome.isCompleted)

        scheduler.releaseSchedule()
        await waitUntil({ !scheduler.isArmed }, "late-armed timer is cancelled by the claim re-check")
        XCTAssertFalse(scheduler.isArmed, "no timer may survive a terminal connect outcome")
        XCTAssertFalse(driver.didStart, "consumed claim suppresses the start")
        XCTAssertFalse(scheduler.scheduleTimedOut, "test coordination stayed within bounds")
    }

    // MARK: - Close waits for the in-flight start() tail, including ready-mid-start (P2)

    /// Ready-mid-start: `.ready` wins while `start()` is still executing; `close()` cancels the
    /// ready driver immediately but must NOT return until the gated `start()` tail has finished
    /// and teardown finalized. The final event snapshot is exhaustive (all tasks joined, gate
    /// released, no further path into the driver), proving no event occurs after close returns.
    func testCloseDuringReadyMidStartWaitsForStartTail() async {
        let driver = ReadyMidStartDriver()
        let transport = QUICTransportApple(
            configuration: SMBQUICConfiguration(),
            connectTimeout: 30,
            driverFactory: { _, _, _ in driver },
            deadline: ManualDeadlineScheduler()
        )
        let (connectTask, connectOutcome) = launchConnect(transport)
        await waitUntil({ connectOutcome.isCompleted }, "connect resolves via ready-mid-start")
        XCTAssertNil(connectOutcome.error, "ready wins: connect succeeds while start() is gated")
        await reap(connectTask, ifCompleted: connectOutcome.isCompleted)

        let (closeTask, closeDone) = launchClose(
            transport, marker: { driver.record("close-returned") }
        )
        await waitUntil(
            { transport.pendingCloseWaiterCount == 1 }, "close parked awaiting the start() tail"
        )
        XCTAssertFalse(closeDone.isSet, "close must not return while start() is still executing")
        XCTAssertEqual(
            driver.events, ["start-entered", "cancel"],
            "close cancels the ready driver immediately but keeps waiting for the tail"
        )

        driver.releaseStart()
        await waitUntil({ closeDone.isSet }, "close returns after the start() tail finishes")
        await reap(closeTask, ifCompleted: closeDone.isSet)
        XCTAssertEqual(
            driver.events, ["start-entered", "cancel", "start-returned", "close-returned"],
            "start() returns, teardown finalizes, only then does close return — nothing after"
        )
        XCTAssertEqual(driver.events.filter { $0 == "cancel" }.count, 1, "exactly one cancel")
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

// MARK: - NWError → POSIXError mapping and `.waiting` classification

/// Direct tests of the production translation layer. WHY: the scripted-driver tests inject
/// `QUICConnectionState` values and therefore never exercise `mapState`/`asQUICPOSIXError` — the
/// two lines that actually decide, in production, that a TLS rejection is `EPROTO` and fatal.
/// Spec: "TLS error mapping carries the status" and "Fatal waiting fails fast".
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
final class NWErrorQUICMappingTests: XCTestCase {
    /// A TLS error maps to `EPROTO` carrying the Security `OSStatus` under `NSUnderlyingErrorKey`,
    /// so callers can identify a trust rejection without parsing description text.
    func testTLSErrorMapsToEPROTOWithUnderlyingOSStatus() throws {
        let mapped = NWError.tls(-9808).asQUICPOSIXError()
        XCTAssertEqual(mapped.code, .EPROTO, "a TLS rejection is EPROTO, never ETIMEDOUT")

        let underlying = try XCTUnwrap(
            (mapped as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
            "the OSStatus must travel as an underlying NSError"
        )
        XCTAssertEqual(underlying.domain, NSOSStatusErrorDomain)
        XCTAssertEqual(underlying.code, -9808)
        XCTAssertTrue(
            (mapped as NSError).localizedDescription.contains("-9808"),
            "the description names the numeric status for logs"
        )
    }

    /// `mapState` classifies `.waiting` by `NWError` case: only `.tls` is fatal. WHY: the class is
    /// the single production decision that makes a trust rejection fail fast; deriving it from the
    /// mapped `POSIXError` would be wrong (other sources also produce `EPROTO`).
    func testMapStateClassifiesOnlyTLSWaitsAsFatal() throws {
        guard case .waiting(let tlsError, let tlsClass) = NWConnectionQUICDriver.mapState(
            .waiting(.tls(-9808))
        ) else {
            return XCTFail("a .waiting NWConnection state must stay a .waiting seam state")
        }
        XCTAssertEqual(tlsClass, .fatal, "no path change can heal a TLS rejection")
        XCTAssertEqual(tlsError.code, .EPROTO)
        let underlying = try XCTUnwrap(
            (tlsError as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        )
        XCTAssertEqual(underlying.domain, NSOSStatusErrorDomain)
        XCTAssertEqual(underlying.code, -9808)

        guard case .waiting(let refusedError, let refusedClass) = NWConnectionQUICDriver.mapState(
            .waiting(.posix(.ECONNREFUSED))
        ) else {
            return XCTFail("a .waiting NWConnection state must stay a .waiting seam state")
        }
        XCTAssertEqual(refusedClass, .transient, "a refused connection may succeed on a new path")
        XCTAssertEqual(refusedError.code, .ECONNREFUSED)

        guard case .waiting(_, let dnsClass) = NWConnectionQUICDriver.mapState(
            .waiting(.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchName)))
        ) else {
            return XCTFail("a .waiting NWConnection state must stay a .waiting seam state")
        }
        XCTAssertEqual(dnsClass, .transient, "DNS failures are retryable")
    }

    /// `.failed(.tls(_))` keeps its existing shape — the classification changes `.waiting` only.
    /// WHY: callers get one `EPROTO` + `NSUnderlyingErrorKey` contract regardless of whether
    /// Network.framework reports the rejection as `.waiting` or `.failed`; a divergence here would
    /// make the documented "certificate not trusted" flow depend on which state the OS chose.
    func testMapStateFailedTLSKeepsMappedErrorShape() throws {
        guard case .failed(let error) = NWConnectionQUICDriver.mapState(.failed(.tls(-9808))) else {
            return XCTFail("a .failed NWConnection state must stay a .failed seam state")
        }
        XCTAssertEqual(error.code, .EPROTO)
        let underlying = try XCTUnwrap(
            (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        )
        XCTAssertEqual(underlying.code, -9808)
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
