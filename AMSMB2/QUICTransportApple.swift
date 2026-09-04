//
//  QUICTransportApple.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

#if canImport(Network)

import Foundation
import Network
import Security

// MARK: - Connection driver seam (design D7)

/// How a `.waiting` state should be treated by the connect state machine.
///
/// This is preserved translation information from the `NWError` case (see
/// `QUICConnectionState.waiting`), not a policy decision.
enum QUICWaitClass: Sendable {
    /// A condition a later path change could heal (no route, DNS, refused, …).
    case transient
    /// A condition no path change can heal — a TLS handshake/trust rejection.
    case fatal
}

/// A `NWConnection`-shaped state delivered to the transport, with any `NWError` already mapped to
/// `POSIXError` (so the test double can script states without Network.framework types).
enum QUICConnectionState: Sendable {
    case setup
    case preparing
    /// The connection is waiting (e.g. no route yet, or the TLS handshake was rejected). Carries
    /// the mapped error for diagnostics plus its `QUICWaitClass` — the one bit of the `NWError`
    /// case that `asQUICPOSIXError()` would otherwise erase (design D1). What to do with the class
    /// is policy and lives in `QUICTransportApple.handleState`.
    case waiting(POSIXError, QUICWaitClass)
    case ready
    case failed(POSIXError)
    /// Terminal acknowledgment of a requested cancel.
    case cancelled
}

/// Abstraction over the underlying QUIC connection so the connect state machine and the
/// established-connection lifecycle are testable without a live handshake (design D7). The
/// production implementation is a thin `NWConnection` wrapper; tests inject a scripted double.
/// `Sendable` because the transport hands the driver across its start/teardown GCD queues;
/// conformers guard their own state (`@unchecked Sendable` with an internal lock).
protocol QUICConnectionDriver: AnyObject, Sendable {
    /// Starts the connection. State events are delivered to `onState`; inbound stream bytes (and a
    /// final empty `Data` on stream EOF) or a receive error are delivered to `onReceive`. Both
    /// handlers are invoked serially on the connection's private queue.
    func start(
        onState: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive: @escaping InboundReceiver
    )
    /// Cancels the connection (idempotent). Eventually delivers a `.cancelled` state event.
    func cancel()
    /// Sends `bytes` on the single bidirectional stream.
    func send(_ bytes: Data) async throws
}

// MARK: - Connect deadline seam (design D7)

/// The always-armed connect deadline, injected so expiry is driven deterministically in tests.
/// Production is a `DispatchSourceTimer`; the test double fires on demand.
protocol ConnectDeadlineScheduler: AnyObject {
    /// Arms a one-shot timer for `timeout` seconds; calls `fire` on expiry.
    func schedule(after timeout: TimeInterval, fire: @escaping @Sendable () -> Void)
    /// Cancels a pending timer (idempotent).
    func cancel()
}

// MARK: - Resolved trust (design D5)

/// The trust decision resolved from `SMBQUICConfiguration.trustPolicy` after eager DER
/// conversion (which fails closed with `EINVAL` before any `NWConnection` exists).
enum QUICResolvedTrust {
    case system
    case customRoots(anchors: [SecCertificate], host: String)
    case insecure
    /// Capture-only (design D2): record the peer's DER chain into `slot` and then always reject
    /// the handshake. Internal and unreachable from any public `SMBQUICConfiguration.TrustPolicy`
    /// — only `SMBQUICCertificateProbe` installs it, via the internal driver-factory seam.
    case capture(QUICCertificateCaptureSlot)
}

// MARK: - QUICTransportApple

/// An `SMBTransport` backed directly by `NWConnection` with `NWProtocolQUIC` (design D1/D2).
///
/// One instance maps to one QUIC connection lifetime, and `connect(host:port:)` is strictly
/// **one-shot**: the first call atomically reserves the instance's single connect attempt, and
/// every other call is rejected deterministically without creating a driver or any network
/// activity — `POSIXError(.EALREADY)` while the attempt is in flight or after it failed (retry
/// after a failed attempt is NOT supported; build a fresh transport, as `SMB2Client` does),
/// `POSIXError(.EISCONN)` once connected, and `POSIXError(.ECONNABORTED)` after `close()`.
/// After `close()` the instance is unusable; create a fresh one to reconnect. Availability
/// floor is spelled out explicitly, including macCatalyst 15 (Package.swift declares
/// `.macCatalyst(.v13)`).
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
public final class QUICTransportApple: SMBTransport, @unchecked Sendable {
    // MARK: - Injected collaborators

    private let configuration: SMBQUICConfiguration
    /// The validated, normalized connect deadline in seconds (design D10). Internal (not
    /// `private`) so tests can observe normalization through the public initializer.
    let connectTimeout: TimeInterval
    private let driverFactory: (_ host: String, _ port: Int, _ trust: QUICResolvedTrust) -> any QUICConnectionDriver
    private let deadline: any ConnectDeadlineScheduler
    /// Dedicated (non-cooperative) queue for the whole connect attempt after the continuation
    /// store — deadline arming, the commit, `driver.start()`, and the post-start handoff — so
    /// none of it ever occupies a Swift cooperative-pool thread: a driver or scheduler that
    /// blocks inside `start()`/`schedule()` (the deterministic race tests do) parks a GCD
    /// worker only, and the connect task suspends on its continuation meanwhile (design D7).
    private let startQueue = DispatchQueue(label: "org.amsmb2.quic.start")
    /// Dedicated (non-cooperative) queue for the close owner's resource teardown (driver
    /// cancellation, waiter resumption), awaited by `close()` — same rationale as `startQueue`.
    private let teardownQueue = DispatchQueue(label: "org.amsmb2.quic.teardown")

    // MARK: - Lock-guarded state (design D3)

    private let lock = NSLock()

    /// Connect-phase state, doubling as the one-shot attempt reservation: `connect` may only
    /// transition `.idle → .reserved` (atomically, before any driver exists), so exactly one
    /// call ever owns the attempt; every other call is rejected by the state it observes
    /// (`.reserved`/`.connecting` → `EALREADY`, `.ready` → `EISCONN`, `.failed` → `EALREADY`;
    /// retry after failure is unsupported — one instance, one attempt). The continuation is
    /// taken by the single winning completion path.
    private enum ConnectState {
        case idle
        /// The single attempt is claimed; trust resolution/driver construction are running and
        /// the continuation is not stored yet.
        case reserved
        case connecting(CheckedContinuation<Void, any Error>)
        case ready
        /// Attempt consumed unsuccessfully (failure/cancel/close/deadline/validation).
        case failed
    }

    private var connectState: ConnectState = .idle
    /// Set by the task-cancellation handler; consumed by the continuation store on `startQueue`
    /// (which runs outside the task context, so it cannot consult `Task.isCancelled` itself).
    private var cancelRequested = false

    /// Established-connection lifecycle with recorded causes (design D8). Only meaningful after
    /// `.ready` has won. `closed` records the local-close cause so the resulting `.cancelled`
    /// event is never misread as abnormal loss; `failed` is abnormal transport loss.
    private enum Lifecycle {
        case active
        case closed
        case failed
    }

    private var lifecycle: Lifecycle = .active

    /// Retained after `.ready` for `send`/`receive`; cleared by whichever losing path cancels it.
    private var driver: (any QUICConnectionDriver)?
    /// Where the connect claim stands relative to `driver.start()` (design D7). The transition to
    /// `.starting` is the atomic commit toward starting the driver; a loser that wins the claim
    /// (cancel/close/failure/deadline) consults it to decide who performs the single teardown:
    /// `.notStarted` → the loser forbids the start forever and cancels nothing; `.starting` →
    /// start is committed (executing or imminent), so the loser parks its outcome in
    /// `pendingLoss` and the starting path finishes it — cancel exactly once, then resume,
    /// then complete any parked `close()` callers — after `start()` returns, so the driver is
    /// never cancelled before its start side effect, no connection activity begins after a
    /// losing resume, and `close()` never returns while that teardown is pending; `.started` →
    /// the loser cancels the started driver exactly once itself.
    private enum StartPhase {
        case notStarted
        case starting
        case started
        case forbidden
    }

    private var startPhase: StartPhase = .notStarted
    /// A losing outcome that won while `startPhase == .starting`; consumed exactly once by the
    /// starting path's post-`start()` handoff.
    private var pendingLoss: (continuation: CheckedContinuation<Void, any Error>, error: any Error)?
    /// `true` from the continuation store until the connect attempt's `startQueue` block has
    /// fully finished — deadline arming (including the late-armed-timer re-check), the commit,
    /// `driver.start()`, and the complete post-start handoff. While set, the close owner parks
    /// in `connectWorkWaiters` before finalizing: `SMBTransport.close()` promises all resources
    /// are released when it returns, so no start, receive-arm, parked-loss teardown, or
    /// late-armed timer may still be pending at that point (design D7).
    private var connectWorkInFlight = false
    /// Close owner(s) parked until the in-flight connect work completes (design D7).
    private var connectWorkWaiters: [CheckedContinuation<Void, Never>] = []

    /// Close lifecycle (design D7/D8). The first `close()` caller atomically becomes the
    /// teardown owner (`.open → .closing`); callers arriving during `.closing` park in
    /// `closeWaiters` and are resumed only after the owner has fully finished — resources
    /// released, in-flight connect work drained — and transitioned to `.closed`. A call after
    /// `.closed` returns immediately (the terminal no-op).
    private enum CloseState: Equatable {
        case open
        case closing
        case closed
    }

    private var closeState: CloseState = .open
    /// `close()` callers parked while another caller owns the teardown (`closeState == .closing`).
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Last `.waiting` error, folded into the `ETIMEDOUT` description on deadline expiry.
    private var lastWaitingError: POSIXError?
    /// `true` once `.ready` won the connect claim — gates `send(_:)`'s never-connected `ENOTCONN` and
    /// every inbound delivery (`takeReceiverLocked`: nothing produced before readiness is delivered).
    private var everReady = false

    /// The receiver supplied to `connect(host:port:onReceive:)`, stored only after the one-shot
    /// reservation succeeded (so a rejected repeat connect can never replace the live one) and
    /// released when `close()` publishes `.closed`. Guarded by `lock`; read under the lock and
    /// invoked outside it.
    private var onReceive: InboundReceiver?
    /// Set once a terminal delivery (peer EOF or a failure) has been made, or `close()` has
    /// begun. One flag across all four producers — the EOF branch, the chunk-path failure, a
    /// post-ready `.failed` and a post-ready `.cancelled` — because the EOF branch deliberately
    /// does not move `lifecycle` (a peer EOF is not a failure), so without it the connection's
    /// routine `.cancelled` after a peer EOF would deliver a failure *after* a terminal
    /// delivery. Guarded by `lock`.
    private var deliveryTerminated = false

    // MARK: - Init

    /// Production initializer: real `NWConnection` driver and `DispatchSourceTimer` deadline.
    ///
    /// The connect deadline is derived from `configuration.connectTimeout` — the single source
    /// of truth (design D10) — and validated/normalized here, so a constructed transport can
    /// never hold an invalid deadline: `NaN`, `±infinity`, zero, and negative values throw
    /// `POSIXError(.EINVAL)` before any `NWConnection` exists; values above 3600 s clamp to
    /// 3600; all other finite positive values (including sub-second) pass unchanged. The
    /// deadline is always armed and independent of `SMB2Manager.timeout`.
    ///
    /// - Parameter configuration: the immutable QUIC configuration snapshot (design D6).
    public convenience init(configuration: SMBQUICConfiguration) throws {
        self.init(
            configuration: configuration,
            connectTimeout: try SMB2Client.normalizedQUICConnectTimeout(configuration.connectTimeout),
            driverFactory: { host, port, trust in
                NWConnectionQUICDriver(host: host, port: port, trust: trust)
            },
            deadline: DispatchDeadlineScheduler()
        )
    }

    /// Test initializer: inject a scripted `QUICConnectionDriver` factory and a fire-on-demand
    /// `ConnectDeadlineScheduler` (design D7). Not part of the public surface.
    init(
        configuration: SMBQUICConfiguration,
        connectTimeout: TimeInterval,
        driverFactory: @escaping (_ host: String, _ port: Int, _ trust: QUICResolvedTrust) -> any QUICConnectionDriver,
        deadline: any ConnectDeadlineScheduler
    ) {
        self.configuration = configuration
        self.connectTimeout = connectTimeout
        self.driverFactory = driverFactory
        self.deadline = deadline
    }

    // MARK: - SMBTransport: connect (design D7)

    /// Establishes the QUIC connection as a self-contained **one-shot** state machine with a
    /// deterministic, always-armed deadline (design D7). Does not rely on libsmb2's
    /// cancellation/timeout machinery, which is not installed during the eager transport connect.
    ///
    /// One-shot contract: the first call atomically reserves the instance's single connect
    /// attempt **before** trust resolution or driver construction, so a rejected call performs
    /// no work at all (no driver, no network activity) and can never overwrite the owning
    /// attempt's continuation, driver, deadline, or start phase. Rejected calls fail promptly:
    /// `EALREADY` while the attempt is in flight, `EISCONN` after success, `EALREADY` after a
    /// failed attempt (retry is unsupported — one instance per connection lifetime; build a
    /// fresh transport instead), `ECONNABORTED` after `close()`. An accepted attempt that fails
    /// validation (e.g. `EINVAL` trust material) also consumes the one shot.
    ///
    /// `onReceive` is stored in the same critical section that reserves the attempt, so it is
    /// installed only when the reservation succeeded: a rejected repeat `connect` never replaces
    /// the live receiver.
    public func connect(
        host: String, port: Int,
        onReceive: @escaping InboundReceiver
    ) async throws {
        // Cancellation before the reservation: nothing is consumed, no NWConnection is created.
        try Task.checkCancellation()

        // One-shot attempt reservation (atomic; before any driver/trust work).
        try lock.withLock {
            guard closeState == .open else {
                throw POSIXError(.ECONNABORTED, description: "QUICTransportApple: connect after close()")
            }
            switch connectState {
            case .idle:
                connectState = .reserved
            case .reserved, .connecting:
                throw POSIXError(.EALREADY, description: "QUICTransportApple: connect already in progress")
            case .ready:
                throw POSIXError(.EISCONN, description: "QUICTransportApple: already connected")
            case .failed:
                throw POSIXError(
                    .EALREADY,
                    description: "QUICTransportApple: one-shot connect attempt already consumed"
                )
            }
            // Reached only by the `.idle` case above — the reservation is ours.
            self.onReceive = onReceive
        }

        // Eager, fail-closed trust resolution BEFORE any connection object exists (design D5):
        // invalid DER and the empty custom-roots set throw `EINVAL` before network activity.
        // A validation failure consumes the reserved attempt (one-shot).
        let trust: QUICResolvedTrust
        do {
            trust = try Self.resolveTrust(configuration.trustPolicy, host: host)
        } catch {
            lock.withLock { connectState = .failed }
            throw error
        }

        let driver = driverFactory(host, port, trust)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // The whole attempt after this point — store, deadline arming, commit, start,
                // handoff — runs on the dedicated start queue (never a cooperative thread); the
                // connect task suspends on the continuation meanwhile (design D7).
                startQueue.async { [self] in
                    runConnectAttempt(continuation, driver: driver)
                }
            }
        } onCancel: {
            // Order matters: set the flag first so a store that has not run yet aborts, then
            // claim a stored continuation. Exactly one of the two acts.
            lock.withLock { cancelRequested = true }
            resolveConnect(.taskCancelled)
        }
    }

    /// The connect attempt body, serialized on `startQueue` (design D7): store the continuation
    /// (re-checking close/cancellation so a racer never strands it), arm the deadline, commit
    /// toward `driver.start()`, start, then perform the post-start handoff. `connectWorkInFlight`
    /// spans this entire block once the store succeeds, so `close()` can wait for the full tail.
    private func runConnectAttempt(
        _ continuation: CheckedContinuation<Void, any Error>, driver: any QUICConnectionDriver
    ) {
        enum StoreAction { case proceed, closed, cancelled }
        let action: StoreAction = lock.withLock {
            guard closeState == .open else {
                connectState = .failed
                return .closed
            }
            guard !cancelRequested else {
                connectState = .failed
                return .cancelled
            }
            connectState = .connecting(continuation)
            self.driver = driver
            connectWorkInFlight = true
            return .proceed
        }
        switch action {
        case .closed:
            continuation.resume(
                throwing: POSIXError(.ECONNABORTED, description: "QUIC connect aborted by close()")
            )
            return
        case .cancelled:
            continuation.resume(throwing: CancellationError())
            return
        case .proceed:
            break
        }

        // Arm the always-on deadline. Arming may itself resolve the connect (a scheduler that
        // fires synchronously, or a real timer racing) — hence the claim re-check below.
        deadline.schedule(after: connectTimeout) { [weak self] in
            self?.resolveConnect(.deadline)
        }

        // Commit toward starting the driver, atomically with the claim (design D7): if a
        // close()/deadline/cancel winner consumed the claim in the window after the store
        // lock released, it recorded the start as forbidden and this body starts nothing.
        // Once `.starting` is committed, a loser that wins before `start()` returns parks its
        // outcome instead of cancelling — the handoff below finishes it, so the driver is
        // never cancelled before its start side effect and never started after a losing
        // teardown.
        let mayStart: Bool = lock.withLock {
            guard case .connecting = connectState else { return false }
            startPhase = .starting
            return true
        }
        guard mayStart else {
            // The claim was consumed while (or before) the timer was arming, so the loser's
            // `deadline.cancel()` may have run before `schedule` recorded the timer. Cancel
            // again (idempotent) so no late-armed timer survives the terminal outcome.
            deadline.cancel()
            finishConnectWork()
            return
        }

        driver.start(
            onState: { [weak self] state in self?.handleState(state) },
            onReceive: { [weak self] result in self?.handleReceive(result) }
        )
        // Post-start handoff: finish a loss that won while start was committed — exactly one
        // cancel of the started driver, the continuation resumes only after it. `.started` is
        // published in the same critical section that consumes the parked loss, so a loss
        // arriving after it self-serves its own teardown.
        let loss = lock.withLock {
            () -> (continuation: CheckedContinuation<Void, any Error>, error: any Error)? in
            startPhase = .started
            defer { pendingLoss = nil }
            return pendingLoss
        }
        if let loss {
            deadline.cancel()
            driver.cancel()
            loss.continuation.resume(throwing: loss.error)
        }
        finishConnectWork()
    }

    /// Marks the connect attempt's `startQueue` block finished and resumes any close owner
    /// parked on it (design D7): only after this may `close()` finalize, so a returned
    /// `close()` proves no start, receive-arm, parked-loss teardown, or late-armed timer is
    /// still outstanding.
    private func finishConnectWork() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            connectWorkInFlight = false
            let waiters = connectWorkWaiters
            connectWorkWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: ())
        }
    }

    // MARK: - Connect outcome claim (design D7)

    /// The outcome a completion path attempts to claim.
    private enum ConnectOutcome {
        case ready
        case failed(POSIXError)
        case taskCancelled
        case closed
        case deadline
    }

    /// The duty a losing winner performs outside the lock (or `nil` when the loss was parked for
    /// the starting path's handoff).
    private struct LossDuty {
        let continuation: CheckedContinuation<Void, any Error>
        let error: any Error
        let driverToCancel: (any QUICConnectionDriver)?
    }

    /// Consumes a losing connect claim. MUST be called while holding `lock`, with `continuation`
    /// just taken from `.connecting`. Encodes the atomic start/loss handoff (design D7):
    /// pre-commit losses forbid the start forever (nothing to cancel); losses in the
    /// commit-to-start window are parked in `pendingLoss` for the starting path (which cancels
    /// the started driver exactly once, then resumes) and return `nil`; post-start losses cancel
    /// the started driver themselves.
    private func consumeLossClaimLocked(
        _ continuation: CheckedContinuation<Void, any Error>, error: any Error
    ) -> LossDuty? {
        connectState = .failed
        switch startPhase {
        case .notStarted:
            startPhase = .forbidden // the setup body must never start the driver now.
            driver = nil
            return LossDuty(continuation: continuation, error: error, driverToCancel: nil)
        case .starting:
            pendingLoss = (continuation, error) // the starting path finishes this loss.
            driver = nil
            return nil
        case .started, .forbidden:
            let toCancel = driver
            driver = nil
            return LossDuty(continuation: continuation, error: error, driverToCancel: toCancel)
        }
    }

    /// Atomically claims the connect outcome: decides the winner AND assigns the side-effect duty
    /// in one critical section (design D7); the effects themselves run outside the lock, performed
    /// by whichever party the assignment named. Exactly one path wins
    /// (`connectState == .connecting`); losers observe the resolved state and perform NO side
    /// effects. Who executes the duty:
    /// - `.ready` wins → this path cancels the deadline timer and RETAINS the driver.
    /// - losing outcome, pre-commit → this path forbids the start, cancels the deadline timer,
    ///   and resumes; there is no driver to cancel.
    /// - losing outcome in the commit-to-start window → this path performs NOTHING; the loss is
    ///   parked and the starting path cancels the deadline timer and the driver, then resumes,
    ///   then completes any `close()` callers parked on the pending teardown.
    /// - losing outcome post-start → this path cancels the deadline timer and the driver itself.
    ///
    /// So the deadline timer is cancelled exactly once, but NOT always by the winner — moving the
    /// cancel unconditionally into the winner reintroduces the cancel-before-start-side-effect bug.
    private func resolveConnect(_ outcome: ConnectOutcome) {
        enum Duty {
            case ready(CheckedContinuation<Void, any Error>)
            case loss(LossDuty)
        }
        let duty: Duty? = lock.withLock {
            guard case .connecting(let continuation) = connectState else { return nil }
            // `.ready` returns from this closure, so `lossError` is definitely initialized on
            // every path that reaches its use below.
            let lossError: any Error
            switch outcome {
            case .ready:
                connectState = .ready
                everReady = true
                // Keep `driver` for send/receive; no cancellation.
                return .ready(continuation)
            case .failed(let error):
                lossError = error
            case .taskCancelled:
                lossError = CancellationError()
            case .closed:
                lossError = POSIXError(.ECONNABORTED, description: "QUIC connect aborted by close()")
            case .deadline:
                let description = lastWaitingError.map {
                    "QUIC connect timed out after \(connectTimeout)s; last waiting error: \($0)"
                } ?? "QUIC connect timed out after \(connectTimeout)s"
                lossError = POSIXError(.ETIMEDOUT, description: description)
            }
            // Every non-ready outcome makes this `connect` throw, so its handler must never be
            // invoked: the receiver was installed at the reservation and the driver arms its
            // receive before `.ready`, so it stays reachable through a failing connect. Set
            // before the claim is consumed, so a loss parked for the commit-to-start handoff is
            // covered too. Mirrors what `close()` does at the `open → closing` transition.
            deliveryTerminated = true
            return consumeLossClaimLocked(continuation, error: lossError).map(Duty.loss)
        }
        guard let duty else { return } // lost the claim, or loss parked for the handoff (D7).
        deadline.cancel()
        switch duty {
        case .ready(let continuation):
            continuation.resume(returning: ())
        case .loss(let loss):
            loss.driverToCancel?.cancel()
            loss.continuation.resume(throwing: loss.error)
        }
    }

    // MARK: - State handling (design D7 connect + D8 post-ready)

    private func handleState(_ state: QUICConnectionState) {
        switch state {
        case .setup, .preparing:
            return // progress; no action.
        case .waiting(let error, .transient):
            lock.withLock { lastWaitingError = error } // diagnostic for the deadline's message.
            return // non-terminal: keep waiting (design D7).
        case .waiting(let error, .fatal):
            // Recorded for the fatal class too (design D4): if the deadline claims the outcome
            // between this record and the claim below, its message still names the TLS status.
            lock.withLock { lastWaitingError = error }
            handleFailed(error) // claim the outcome exactly as `.failed` does (design D2).
        case .ready:
            resolveConnect(.ready)
        case .failed(let error):
            handleFailed(error)
        case .cancelled:
            handleCancelled()
        }
    }

    /// `.failed`: a connect-phase failure claims the connect outcome; a post-ready failure is
    /// abnormal transport loss routed to the established-connection lifecycle (design D8).
    private func handleFailed(_ error: POSIXError) {
        enum Action {
            case connectClaim
            case abnormalLoss(InboundReceiver?, (any QUICConnectionDriver)?)
            case ignore
        }
        let action: Action = lock.withLock {
            switch connectState {
            case .connecting:
                return .connectClaim
            case .ready where lifecycle == .active:
                lifecycle = .failed
                let receiver = takeReceiverLocked(terminal: true)
                let toCancel = driver // post-ready ⇒ the driver was started.
                driver = nil
                return .abnormalLoss(receiver, toCancel)
            default:
                return .ignore
            }
        }
        switch action {
        case .connectClaim:
            resolveConnect(.failed(error))
        case .abnormalLoss(let receiver, let toCancel):
            toCancel?.cancel()
            receiver?(.failure(error))
        case .ignore:
            break
        }
    }

    /// `.cancelled`: during connect it is a defensive claim (`ECONNABORTED`); post-ready it is a
    /// no-op acknowledgment when a local close was recorded, or abnormal loss otherwise (design D8).
    private func handleCancelled() {
        enum Action {
            case connectClaim
            case localCloseAck
            case abnormalLoss(InboundReceiver?)
            case ignore
        }
        let action: Action = lock.withLock {
            switch connectState {
            case .connecting:
                return .connectClaim
            case .ready:
                if lifecycle == .active {
                    // No local-close cause recorded → unsolicited cancel = abnormal loss.
                    lifecycle = .failed
                    let receiver = takeReceiverLocked(terminal: true)
                    driver = nil
                    return .abnormalLoss(receiver)
                }
                return .localCloseAck // our own close()'s cancel — no-op on the recorded result.
            default:
                return .ignore
            }
        }
        switch action {
        case .connectClaim:
            resolveConnect(.closed)
        case .localCloseAck, .ignore:
            break
        case .abnormalLoss(let receiver):
            receiver?(.failure(POSIXError(.ECONNRESET, description: "QUIC connection cancelled by peer")))
        }
    }

    // MARK: - Inbound delivery (design D8)

    /// Inbound events from the driver. Nothing is delivered before `.ready` has won the connect
    /// claim: the driver arms its receive during setup, and the seam's contract is that a
    /// `connect` which throws never invokes its handler. A setup-time event is therefore dropped
    /// whole — not just its delivery — so it also cannot tear down an attempt that is still
    /// running; a genuine setup failure reaches the caller through the state handler
    /// (`.failed` → `resolveConnect`), which is what resolves the connect.
    private func handleReceive(_ result: Result<Data, POSIXError>) {
        switch result {
        case .success(let data) where data.isEmpty:
            // Peer-originated graceful EOF (stream complete) — terminal.
            let receiver = lock.withLock { takeReceiverLocked(terminal: true) }
            receiver?(.success(Data()))
        case .success(let data):
            let receiver = lock.withLock { takeReceiverLocked(terminal: false) }
            receiver?(.success(data))
        case .failure(let error):
            // A receive-side error is abnormal transport loss (design D8) — terminal.
            let receiver: InboundReceiver? = lock.withLock {
                // `everReady` also gates the state mutation, not only the delivery: nilling
                // `driver` during setup would strand the connect claim's cleanup with nothing
                // to cancel, and fail a connection that was still on its way to `.ready`.
                guard everReady, lifecycle == .active else { return nil }
                lifecycle = .failed
                driver = nil
                return takeReceiverLocked(terminal: true)
            }
            receiver?(.failure(error))
        }
    }

    /// Reads the receiver, consuming the terminal-once flag when `terminal` is set. Returns
    /// `nil` before `.ready` has won the connect claim, once delivery has terminated, or before
    /// a receiver exists. MUST be called while holding `lock`; the returned receiver MUST be
    /// invoked outside it (it takes the bridge's own lock — the two are never nested).
    ///
    /// The `everReady` gate is what makes "a `connect` that throws never invokes its handler"
    /// true for this conformer: the receiver is installed at the reservation and the driver arms
    /// its receive before `.ready`, so it is reachable throughout a failing connect. It is a
    /// no-op for the post-ready state producers, which already require `connectState == .ready`.
    private func takeReceiverLocked(terminal: Bool) -> InboundReceiver? {
        guard everReady, !deliveryTerminated, let receiver = onReceive else { return nil }
        if terminal { deliveryTerminated = true }
        return receiver
    }

    // MARK: - SMBTransport: send / receive / close

    public func send(_ bytes: Data) async throws {
        let driver: (any QUICConnectionDriver)? = lock.withLock {
            (closeState != .open || !everReady) ? nil : self.driver
        }
        guard let driver else {
            throw POSIXError(.ENOTCONN, description: "QUICTransportApple: not connected")
        }
        try await driver.send(bytes)
    }

    /// Closes the connection through the close lifecycle (`open → closing → closed`, design
    /// D7/D8). The first caller atomically becomes the teardown **owner**; it records the
    /// local-close cause under the lock **before** `NWConnection.cancel()` (so the resulting
    /// `.cancelled` state event is never misread as abnormal loss), performs the resource
    /// teardown on the dedicated teardown queue — cancel the driver exactly once, resolve the
    /// connect continuation if close won the claim — then waits for any in-flight connect work
    /// (a committed `start()` that has not returned, its handoff, or the deadline arming tail)
    /// to finish, and only then transitions
    /// to `.closed` and resumes every concurrent caller.
    ///
    /// `SMBTransport.close()` promises resources are released when it returns — for **every**
    /// caller: a `close()` arriving while another caller owns the teardown waits for that same
    /// teardown to complete; only a call made after a prior close fully completed returns
    /// immediately. No lock is held across an await, a driver/deadline call, or a continuation
    /// resumption, and each owned resource is cancelled/resumed exactly once.
    ///
    /// The one connect-phase remnant a returned `close()` may leave behind is resolution-only:
    /// a `connect()` caught between its attempt reservation and its continuation store aborts
    /// itself with `ECONNABORTED` when the store observes the closed lifecycle — it creates no
    /// driver activity and arms no timer (the store aborts before both).
    public func close() async {
        enum Entry {
            case alreadyClosed
            case waitForOwner
            case own(abort: LossDuty?, driverToCancel: (any QUICConnectionDriver)?)
        }
        let entry: Entry = lock.withLock {
            switch closeState {
            case .closed:
                return .alreadyClosed
            case .closing:
                return .waitForOwner
            case .open:
                closeState = .closing
                // Delivery stops the moment close() begins (design D4): the `.cancelled` the
                // teardown below produces must never reach the receiver, so the bridge sees the
                // same silent teardown `TCPTransportApple` gives it.
                deliveryTerminated = true
                if case .connecting(let continuation) = connectState {
                    // close() while connecting wins the connect claim → ECONNABORTED (design
                    // D7). A nil duty means the loss landed in the commit-to-start window and
                    // was parked for the starting path's handoff — the owner performs no
                    // connect teardown itself, but waits below until the handoff completed it.
                    let duty = consumeLossClaimLocked(
                        continuation,
                        error: POSIXError(.ECONNABORTED, description: "QUIC connect aborted by close()")
                    )
                    return .own(abort: duty, driverToCancel: nil)
                }
                // Established (or never-started/reserved): record the local-close cause
                // BEFORE cancel (design D8).
                lifecycle = .closed
                let toCancel = driver
                driver = nil
                return .own(abort: nil, driverToCancel: toCancel)
            }
        }

        switch entry {
        case .alreadyClosed:
            return // terminal no-op: a prior close fully completed.
        case .waitForOwner:
            // Park until the owner's teardown has fully completed (resources released,
            // in-flight connect work drained) and `.closed` was published.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked: Bool = lock.withLock {
                    guard closeState == .closing else { return false } // owner finished meanwhile.
                    closeWaiters.append(continuation)
                    return true
                }
                if !parked {
                    continuation.resume(returning: ())
                }
            }
            return
        case .own(let abort, let driverToCancel):
            // Owner: perform the resource teardown on the dedicated teardown queue (never a
            // cooperative thread) and wait for it to complete before proceeding.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                teardownQueue.async { [self] in
                    if let abort {
                        deadline.cancel()
                        abort.driverToCancel?.cancel()
                        abort.continuation.resume(throwing: abort.error)
                    }
                    driverToCancel?.cancel()
                    continuation.resume(returning: ())
                }
            }
            // Wait for in-flight connect work: a parked committed-start teardown (this close's
            // own parked loss or one parked earlier by cancellation/deadline), a still-running
            // `start()` tail (including ready-mid-start), or the deadline-arming tail with its
            // late-armed-timer re-check.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked: Bool = lock.withLock {
                    guard connectWorkInFlight else { return false }
                    connectWorkWaiters.append(continuation)
                    return true
                }
                if !parked {
                    continuation.resume(returning: ())
                }
            }
            // Fully closed: publish and release every concurrent caller.
            let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                closeState = .closed
                onReceive = nil // the receiver is released when close completes (design D4).
                let waiters = closeWaiters
                closeWaiters = []
                return waiters
            }
            for waiter in waiters {
                waiter.resume(returning: ())
            }
        }
    }

    /// Test observability (internal): whether an inbound receiver is currently installed. A
    /// never-connected transport holds none; `close()` releases the one a connect installed.
    var hasInboundHandler: Bool {
        lock.withLock { onReceive != nil }
    }

    /// Test observability (internal, like `connectTimeout`): how many `close()` callers are
    /// currently parked — the owner awaiting in-flight connect work plus concurrent callers
    /// awaiting the owner's completed teardown.
    var pendingCloseWaiterCount: Int {
        lock.withLock { closeWaiters.count + connectWorkWaiters.count }
    }

    // MARK: - Trust resolution (design D5)

    /// Resolves the trust policy into `QUICResolvedTrust`, eagerly converting DER anchors and
    /// failing closed with `EINVAL` on invalid DER or the empty custom-roots set — before any
    /// `NWConnection` exists (design D5).
    static func resolveTrust(
        _ policy: SMBQUICConfiguration.TrustPolicy, host: String
    ) throws -> QUICResolvedTrust {
        switch policy {
        case .system:
            return .system
        case .insecureNoVerification:
            return .insecure
        case .customRoots(let derAnchors):
            guard !derAnchors.isEmpty else {
                throw POSIXError(.EINVAL, description: "SMBQUICConfiguration.customRoots is empty")
            }
            var anchors: [SecCertificate] = []
            anchors.reserveCapacity(derAnchors.count)
            for der in derAnchors {
                guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                    throw POSIXError(.EINVAL, description: "SMBQUICConfiguration.customRoots contains invalid DER")
                }
                anchors.append(certificate)
            }
            return .customRoots(anchors: anchors, host: host)
        }
    }

    /// Evaluates a server `SecTrust` against exactly the supplied `anchors` for `host`, per the
    /// D5 fail-closed sequence (steps 3–6): install the SSL hostname policy, replace the system
    /// anchors with `anchors` only, check every `OSStatus`, then evaluate. Any Security API
    /// failure returns `false`. Factored out so it is unit-testable against `SecTrust` objects
    /// built with `SecTrustCreateWithCertificates` — no live handshake needed.
    static func evaluateCustomRootsTrust(
        _ trust: SecTrust, host: String, anchors: [SecCertificate]
    ) -> Bool {
        // (3) hostname policy — custom roots never disable hostname verification.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { return false }
        // (4) anchors REPLACE the system roots.
        guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess else { return false }
        guard SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        // (5)/(6) evaluate; the boolean result decides verification.
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

// MARK: - Production NWConnection driver (design D2)

/// Thin `NWConnection` wrapper implementing `QUICConnectionDriver`. One QUIC connection with a
/// single bidirectional stream carries the whole SMB session; `send`/`receive` write/read that
/// stream verbatim (design D2 — no SMB-aware inspection). Live behavior is verified at the manual
/// interop gate (tasks 4.x); unit tests use the scripted double instead.
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
final class NWConnectionQUICDriver: QUICConnectionDriver, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.amsmb2.quic.connection")
    private let verifyQueue = DispatchQueue(label: "org.amsmb2.quic.verify")
    let connection: NWConnection?
    let initError: POSIXError?
    private let lock = NSLock()
    private var onReceive: InboundReceiver?

    init(host: String, port: Int, trust: QUICResolvedTrust) {
        // ALPN "smb", SNI = host, TLS 1.3 (QUIC-implied) — design D2.
        let quicOptions = NWProtocolQUIC.Options(alpn: ["smb"])
        let securityOptions = quicOptions.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(securityOptions, host)

        switch trust {
        case .system:
            // Install NO verify block — the system default chain + hostname verification runs.
            break
        case .insecure:
            sec_protocol_options_set_verify_block(
                securityOptions,
                { _, _, complete in complete(true) },
                verifyQueue
            )
        case .customRoots(let anchors, let verifyHost):
            sec_protocol_options_set_verify_block(
                securityOptions,
                { _, trustRef, complete in
                    let secTrust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                    complete(QUICTransportApple.evaluateCustomRootsTrust(
                        secTrust, host: verifyHost, anchors: anchors
                    ))
                },
                verifyQueue
            )
        case .capture(let slot):
            // Capture-only (design D2): record the presented chain, then ALWAYS reject — every
            // path calls `complete(false)` exactly once, so no code path can leave a
            // trusted-but-unauthenticated connection alive. The store happens *before* the
            // completion, and Network.framework only reports the rejection afterwards, so the
            // slot is filled before the transport can observe the failure.
            sec_protocol_options_set_verify_block(
                securityOptions,
                { _, trustRef, complete in
                    let secTrust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                    slot.store(NWConnectionQUICDriver.certificateChainDER(from: secTrust))
                    complete(false)
                },
                verifyQueue
            )
        }

        let parameters = NWParameters(quic: quicOptions)
        // Only 1...65535 is a valid port: `UInt16(exactly:)` rejects negatives and > 65535
        // (which must never silently become UDP/0), and `rawPort > 0` rejects port 0.
        guard let rawPort = UInt16(exactly: port), rawPort > 0,
              let nwPort = NWEndpoint.Port(rawValue: rawPort)
        else {
            self.connection = nil
            self.initError = POSIXError(.EINVAL, description: "QUIC: invalid port \(port)")
            return
        }
        self.connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), using: parameters
        )
        self.initError = nil
    }

    /// The DER-encoded certificate chain of `trust`, **leaf first** (design D3).
    ///
    /// `SecTrustCopyCertificateChain` (iOS 15 / macOS 12 — the QUIC availability floor) returns
    /// the chain as Security.framework sees it, which for a self-signed or private-CA server is
    /// exactly what the peer presented. A `nil` chain yields `[]`, which the capture verify block
    /// treats as "nothing captured".
    static func certificateChainDER(from trust: SecTrust) -> [Data] {
        certificateChainDER(SecTrustCopyCertificateChain(trust))
    }

    /// The DER mapping itself, split out so the `nil`-chain contract is unit-testable without
    /// constructing a `SecTrust` that Security.framework refuses to leave empty.
    static func certificateChainDER(_ chain: CFArray?) -> [Data] {
        guard let certificates = chain as? [SecCertificate] else { return [] }
        return certificates.map { SecCertificateCopyData($0) as Data }
    }

    func start(
        onState: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive: @escaping InboundReceiver
    ) {
        lock.withLock { self.onReceive = onReceive }
        guard let connection else {
            onState(.failed(initError ?? POSIXError(.EINVAL)))
            return
        }
        connection.stateUpdateHandler = { state in onState(Self.mapState(state)) }
        connection.start(queue: queue)
        armReceive()
    }

    /// Re-arming inbound receive on the single stream (design D2/D8). Each completion appends to
    /// the transport's FIFO via `onReceive` and re-arms; stream completion delivers empty `Data`.
    private func armReceive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            let handler = self.lock.withLock { self.onReceive }
            if let error {
                handler?(.failure(error.asQUICPOSIXError()))
                return
            }
            if let content, !content.isEmpty {
                handler?(.success(content))
            }
            if isComplete {
                handler?(.success(Data())) // stream EOF.
                return
            }
            self.armReceive()
        }
    }

    func cancel() {
        connection?.cancel()
        // Clear the state/receive handlers so no callback retains anything past teardown
        // (design D7: the winner "clears the stored reference and its stateUpdateHandler").
        connection?.stateUpdateHandler = nil
        lock.withLock { onReceive = nil }
    }

    func send(_ bytes: Data) async throws {
        guard let connection else {
            throw initError ?? POSIXError(.ENOTCONN)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error.asQUICPOSIXError())
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    /// Maps `NWConnection.State` to the driver-neutral `QUICConnectionState`, converting any
    /// `NWError` to `POSIXError` (the transport never sees a raw Network.framework error).
    static func mapState(_ state: NWConnection.State) -> QUICConnectionState {
        switch state {
        case .setup:
            return .setup
        case .preparing:
            return .preparing
        case .waiting(let error):
            // Only a TLS handshake/trust rejection is unhealable by a path change (design D1).
            let waitClass: QUICWaitClass = if case .tls = error { .fatal } else { .transient }
            return .waiting(error.asQUICPOSIXError(), waitClass)
        case .ready:
            return .ready
        case .failed(let error):
            return .failed(error.asQUICPOSIXError())
        case .cancelled:
            return .cancelled
        @unknown default:
            return .failed(POSIXError(.EIO, description: "unknown NWConnection state: \(state)"))
        }
    }
}

// MARK: - Production deadline scheduler

/// `DispatchSourceTimer`-backed `ConnectDeadlineScheduler` (design D7).
final class DispatchDeadlineScheduler: ConnectDeadlineScheduler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.amsmb2.quic.deadline")
    private let lock = NSLock()
    private var timer: (any DispatchSourceTimer)?

    func schedule(after timeout: TimeInterval, fire: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler(handler: fire)
        lock.withLock {
            self.timer?.cancel()
            self.timer = timer
        }
        timer.resume()
    }

    func cancel() {
        let timer: (any DispatchSourceTimer)? = lock.withLock {
            let existing = self.timer
            self.timer = nil
            return existing
        }
        timer?.cancel()
    }
}

// MARK: - NWError → POSIXError (QUIC)

@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
extension NWError {
    /// Maps a Network.framework error to `POSIXError` (never a raw `NWError`; CLAUDE.md convention).
    func asQUICPOSIXError() -> POSIXError {
        switch self {
        case .posix(let code):
            return POSIXError(code)
        case .dns:
            return POSIXError(.EHOSTUNREACH, description: "QUIC DNS resolution failed: \(self)")
        case .tls(let status):
            // The Security status travels as an underlying error so callers can identify a
            // trust rejection without parsing the description (design D3).
            return POSIXError(.EPROTO, userInfo: [
                NSLocalizedDescriptionKey: "QUIC TLS error: \(self)",
                NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: Int(status)),
            ])
        case .wifiAware:
            return POSIXError(.ENETUNREACH, description: "QUIC Wi-Fi Aware error: \(self)")
        @unknown default:
            return POSIXError(.EIO, description: "QUIC network error: \(self)")
        }
    }
}

#endif // canImport(Network)
