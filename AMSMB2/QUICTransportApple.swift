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

/// A `NWConnection`-shaped state delivered to the transport, with any `NWError` already mapped to
/// `POSIXError` (so the test double can script states without Network.framework types).
enum QUICConnectionState: Sendable {
    case setup
    case preparing
    /// Non-terminal: the connection is waiting (e.g. no route yet). Carries the mapped error for
    /// diagnostics; only cancellation or the deadline ends a stuck wait (design D7).
    case waiting(POSIXError)
    case ready
    case failed(POSIXError)
    /// Terminal acknowledgment of a requested cancel.
    case cancelled
}

/// Abstraction over the underlying QUIC connection so the connect state machine and the
/// established-connection lifecycle are testable without a live handshake (design D7). The
/// production implementation is a thin `NWConnection` wrapper; tests inject a scripted double.
protocol QUICConnectionDriver: AnyObject {
    /// Starts the connection. State events are delivered to `onState`; inbound stream bytes (and a
    /// final empty `Data` on stream EOF) or a receive error are delivered to `onReceive`. Both
    /// handlers are invoked serially on the connection's private queue.
    func start(
        onState: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive: @escaping @Sendable (Result<Data, POSIXError>) -> Void
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
}

// MARK: - QUICTransportApple

/// An `SMBTransport` backed directly by `NWConnection` with `NWProtocolQUIC` (design D1/D2).
///
/// One instance maps to one QUIC connection lifetime. After `close()` the instance is unusable;
/// create a fresh one to reconnect. Availability floor is spelled out explicitly, including
/// macCatalyst 15 (Package.swift declares `.macCatalyst(.v13)`).
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
public final class QUICTransportApple: SMBTransport, @unchecked Sendable {
    // MARK: - Injected collaborators

    private let configuration: SMBQUICConfiguration
    private let connectTimeout: TimeInterval
    private let driverFactory: (_ host: String, _ port: Int, _ trust: QUICResolvedTrust) -> any QUICConnectionDriver
    private let deadline: any ConnectDeadlineScheduler

    // MARK: - Lock-guarded state (design D3)

    private let lock = NSLock()

    /// Connect-phase state. The continuation is taken by the single winning completion path.
    private enum ConnectState {
        case idle
        case connecting(CheckedContinuation<Void, any Error>)
        case ready
        /// Connect resolved with a failure/cancel/close/deadline (claim consumed).
        case failed
    }

    private var connectState: ConnectState = .idle

    /// Established-connection lifecycle with recorded causes (design D8). Only meaningful after
    /// `.ready` has won. `localClosing`/`closed` record a local-close cause so the resulting
    /// `.cancelled` event is never misread as abnormal loss; `failed` is abnormal transport loss.
    private enum Lifecycle {
        case active
        case localClosing
        case closed
        case failed
    }

    private var lifecycle: Lifecycle = .active

    /// Retained after `.ready` for `send`/`receive`; cleared by whichever losing path cancels it.
    private var driver: (any QUICConnectionDriver)?
    /// `true` once the setup body has committed to `driver.start()` while still holding the connect
    /// claim. A losing winner (cancel/close/deadline) cancels the driver ONLY if it was started —
    /// so a winner that claims before start performs no cancellation and the setup body starts
    /// nothing (design D7 "losers perform no side effects").
    private var driverStarted = false
    /// Last `.waiting` error, folded into the `ETIMEDOUT` description on deadline expiry.
    private var lastWaitingError: POSIXError?
    /// `true` once `.ready` won the connect claim — gates `receive()`'s never-connected `ENOTCONN`.
    private var everReady = false
    /// Set by `close()`; makes `receive()` return empty `Data` and `close()` idempotent.
    private var isClosed = false

    /// Inbound chunk FIFO (bytes arrived faster than consumed) + a single parked `receive()`.
    private var inboundChunks: [Data] = []
    private var inboundEOF = false
    private var receiveError: POSIXError?
    private var receiveWaiter: CheckedContinuation<Data, any Error>?

    // MARK: - Init

    /// Production initializer: real `NWConnection` driver and `DispatchSourceTimer` deadline.
    ///
    /// - Parameters:
    ///   - configuration: the immutable QUIC configuration snapshot (design D6).
    ///   - connectTimeout: the validated, normalized connect deadline in seconds (design D10) —
    ///     sourced from `SMBQUICConfiguration.connectTimeout`, independent of `SMB2Manager.timeout`.
    public convenience init(configuration: SMBQUICConfiguration, connectTimeout: TimeInterval) {
        self.init(
            configuration: configuration,
            connectTimeout: connectTimeout,
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

    /// Establishes the QUIC connection as a self-contained one-shot state machine with a
    /// deterministic, always-armed deadline (design D7). Does not rely on libsmb2's
    /// cancellation/timeout machinery, which is not installed during the eager transport connect.
    public func connect(host: String, port: Int) async throws {
        // Cancellation before start: no NWConnection is created.
        try Task.checkCancellation()

        // Eager, fail-closed trust resolution BEFORE any connection object exists (design D5):
        // invalid DER and the empty custom-roots set throw `EINVAL` before network activity.
        let trust = try Self.resolveTrust(configuration.trustPolicy, host: host)

        let driver = driverFactory(host, port, trust)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Store the continuation + driver under the lock, re-checking cancellation/close
                // so a cancel that raced the store never leaves the continuation orphaned.
                enum StartAction { case started, cancelled, closed }
                let action: StartAction = lock.withLock {
                    if isClosed {
                        return .closed
                    }
                    if Task.isCancelled {
                        return .cancelled
                    }
                    connectState = .connecting(continuation)
                    self.driver = driver
                    return .started
                }
                switch action {
                case .closed:
                    continuation.resume(throwing: POSIXError(.ECONNABORTED))
                    return
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                    return
                case .started:
                    break
                }

                // Arm the always-on deadline. Arming may itself resolve the connect (a scheduler
                // that fires synchronously, or a real timer racing) — hence the claim re-check below.
                deadline.schedule(after: connectTimeout) { [weak self] in
                    self?.resolveConnect(.deadline)
                }

                // Gate the start on STILL holding the claim (design D7 "losers perform no side
                // effects"): if a close()/deadline winner consumed the claim in the window after the
                // store lock released, it owns teardown and the setup body starts nothing. Marking
                // `driverStarted` under the lock lets a later winner know a started driver must be
                // cancelled, while a winner that claimed before this point cancels nothing.
                let mayStart: Bool = lock.withLock {
                    guard case .connecting = connectState else { return false }
                    driverStarted = true
                    return true
                }
                guard mayStart else { return } // winner already resumed the continuation.
                driver.start(
                    onState: { [weak self] state in self?.handleState(state) },
                    onReceive: { [weak self] result in self?.handleReceive(result) }
                )
            }
        } onCancel: {
            resolveConnect(.taskCancelled)
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

    /// Atomically claims the connect outcome: decides the winner AND assigns the side-effect duty
    /// in one critical section (design D7). Exactly one path wins (`connectState == .connecting`);
    /// losers observe the resolved state and perform NO side effects. On `.ready` the connection
    /// is retained; on any losing outcome the winner cancels+releases it exactly once. The winner
    /// always cancels the deadline timer.
    private func resolveConnect(_ outcome: ConnectOutcome) {
        struct Duty {
            let continuation: CheckedContinuation<Void, any Error>
            let error: (any Error)?
            let driverToCancel: (any QUICConnectionDriver)?
        }
        let duty: Duty? = lock.withLock {
            guard case .connecting(let continuation) = connectState else { return nil }
            switch outcome {
            case .ready:
                connectState = .ready
                everReady = true
                // Keep `driver` for send/receive; no cancellation.
                return Duty(continuation: continuation, error: nil, driverToCancel: nil)
            case .failed(let error):
                connectState = .failed
                let toCancel = driverStarted ? driver : nil
                driver = nil
                return Duty(continuation: continuation, error: error, driverToCancel: toCancel)
            case .taskCancelled:
                connectState = .failed
                let toCancel = driverStarted ? driver : nil
                driver = nil
                return Duty(continuation: continuation, error: CancellationError(), driverToCancel: toCancel)
            case .closed:
                connectState = .failed
                let toCancel = driverStarted ? driver : nil
                driver = nil
                return Duty(
                    continuation: continuation,
                    error: POSIXError(.ECONNABORTED, description: "QUIC connect aborted by close()"),
                    driverToCancel: toCancel
                )
            case .deadline:
                connectState = .failed
                let toCancel = driverStarted ? driver : nil
                driver = nil
                let description = lastWaitingError.map {
                    "QUIC connect timed out after \(connectTimeout)s; last waiting error: \($0)"
                } ?? "QUIC connect timed out after \(connectTimeout)s"
                return Duty(
                    continuation: continuation,
                    error: POSIXError(.ETIMEDOUT, description: description),
                    driverToCancel: toCancel
                )
            }
        }
        guard let duty else { return } // lost the claim → no side effects (design D7).
        deadline.cancel()
        duty.driverToCancel?.cancel()
        if let error = duty.error {
            duty.continuation.resume(throwing: error)
        } else {
            duty.continuation.resume(returning: ())
        }
    }

    // MARK: - State handling (design D7 connect + D8 post-ready)

    private func handleState(_ state: QUICConnectionState) {
        switch state {
        case .setup, .preparing:
            return // progress; no action.
        case .waiting(let error):
            lock.withLock { lastWaitingError = error }
            return // non-terminal: keep waiting (design D7).
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
            case abnormalLoss(CheckedContinuation<Data, any Error>?, (any QUICConnectionDriver)?)
            case ignore
        }
        let action: Action = lock.withLock {
            switch connectState {
            case .connecting:
                return .connectClaim
            case .ready where lifecycle == .active:
                lifecycle = .failed
                receiveError = error
                let waiter = receiveWaiter
                receiveWaiter = nil
                let toCancel = driverStarted ? driver : nil
                driver = nil
                return .abnormalLoss(waiter, toCancel)
            default:
                return .ignore
            }
        }
        switch action {
        case .connectClaim:
            resolveConnect(.failed(error))
        case .abnormalLoss(let waiter, let toCancel):
            toCancel?.cancel()
            waiter?.resume(throwing: error)
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
            case abnormalLoss(CheckedContinuation<Data, any Error>?)
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
                    let error = POSIXError(.ECONNRESET, description: "QUIC connection cancelled by peer")
                    receiveError = error
                    let waiter = receiveWaiter
                    receiveWaiter = nil
                    driver = nil
                    return .abnormalLoss(waiter)
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
        case .abnormalLoss(let waiter):
            waiter?.resume(throwing: POSIXError(.ECONNRESET, description: "QUIC connection cancelled by peer"))
        }
    }

    // MARK: - Inbound delivery (design D8)

    private func handleReceive(_ result: Result<Data, POSIXError>) {
        switch result {
        case .success(let data) where data.isEmpty:
            // Peer-originated graceful EOF (stream complete): a parked/next receive() sees empty.
            let waiter: CheckedContinuation<Data, any Error>? = lock.withLock {
                inboundEOF = true
                let waiter = receiveWaiter
                receiveWaiter = nil
                return waiter
            }
            waiter?.resume(returning: Data())
        case .success(let data):
            let waiter: CheckedContinuation<Data, any Error>? = lock.withLock {
                if let waiter = receiveWaiter {
                    receiveWaiter = nil
                    return waiter
                }
                inboundChunks.append(data)
                return nil
            }
            waiter?.resume(returning: data)
        case .failure(let error):
            // A receive-side error is abnormal transport loss (design D8).
            let waiter: CheckedContinuation<Data, any Error>? = lock.withLock {
                guard lifecycle == .active else { return nil }
                lifecycle = .failed
                receiveError = error
                let waiter = receiveWaiter
                receiveWaiter = nil
                driver = nil
                return waiter
            }
            waiter?.resume(throwing: error)
        }
    }

    // MARK: - SMBTransport: send / receive / close

    public func send(_ bytes: Data) async throws {
        let driver: (any QUICConnectionDriver)? = lock.withLock {
            (isClosed || !everReady) ? nil : self.driver
        }
        guard let driver else {
            throw POSIXError(.ENOTCONN, description: "QUICTransportApple: not connected")
        }
        try await driver.send(bytes)
    }

    public func receive() async throws -> Data {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                    self.lock.withLock {
                        // Drain buffered chunks before surfacing any EOF/error (design D8 / matches
                        // TCPTransportApple's "drain buffer before EOF").
                        if !inboundChunks.isEmpty {
                            continuation.resume(returning: inboundChunks.removeFirst())
                        } else if isClosed {
                            // After close() → empty Data (the close contract wins over a prior error).
                            continuation.resume(returning: Data())
                        } else if let error = receiveError {
                            continuation.resume(throwing: error) // abnormal loss (pre-close).
                        } else if inboundEOF {
                            continuation.resume(returning: Data()) // peer graceful EOF.
                        } else if !everReady {
                            // Never connected → ENOTCONN (reserved for the never-connected case).
                            continuation.resume(throwing: POSIXError(.ENOTCONN, description: "QUICTransportApple: not connected"))
                        } else if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            receiveWaiter = continuation
                        }
                    }
                }
            },
            onCancel: { [self] in
                let waiter: CheckedContinuation<Data, any Error>? = lock.withLock {
                    let waiter = receiveWaiter
                    receiveWaiter = nil
                    return waiter
                }
                waiter?.resume(throwing: CancellationError())
            }
        )
    }

    /// Closes the connection idempotently. Records the local-close cause under the lock **before**
    /// `NWConnection.cancel()`, so the resulting `.cancelled` state event is never misread as
    /// abnormal loss (design D8); resumes a parked `receive()` with empty `Data` (the local-close
    /// EOF signal, matching `TCPTransportApple.signalClosed()`), and releases resources.
    public func close() async {
        enum Action {
            case noop
            case abortConnect(CheckedContinuation<Void, any Error>, (any QUICConnectionDriver)?)
            case teardown(CheckedContinuation<Data, any Error>?, (any QUICConnectionDriver)?)
        }
        let action: Action = lock.withLock {
            if isClosed {
                return .noop
            }
            isClosed = true
            if case .connecting(let continuation) = connectState {
                // close() while connecting wins the connect claim → ECONNABORTED (design D7).
                connectState = .failed
                let toCancel = driverStarted ? driver : nil
                driver = nil
                return .abortConnect(continuation, toCancel)
            }
            // Established (or never-started): record the local-close cause BEFORE cancel.
            if lifecycle == .active {
                lifecycle = .localClosing
            }
            lifecycle = .closed
            let waiter = receiveWaiter
            receiveWaiter = nil
            let toCancel = driver
            driver = nil
            return .teardown(waiter, toCancel)
        }
        switch action {
        case .noop:
            return
        case .abortConnect(let continuation, let toCancel):
            deadline.cancel()
            toCancel?.cancel()
            continuation.resume(throwing: POSIXError(.ECONNABORTED, description: "QUIC connect aborted by close()"))
        case .teardown(let waiter, let toCancel):
            toCancel?.cancel()
            waiter?.resume(returning: Data()) // local-close EOF signal (empty Data).
        }
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
    private let connection: NWConnection?
    private let initError: POSIXError?
    private let lock = NSLock()
    private var onReceive: (@Sendable (Result<Data, POSIXError>) -> Void)?

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
        }

        let parameters = NWParameters(quic: quicOptions)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else {
            self.connection = nil
            self.initError = POSIXError(.EINVAL, description: "QUIC: invalid port \(port)")
            return
        }
        self.connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), using: parameters
        )
        self.initError = nil
    }

    func start(
        onState: @escaping @Sendable (QUICConnectionState) -> Void,
        onReceive: @escaping @Sendable (Result<Data, POSIXError>) -> Void
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
    private static func mapState(_ state: NWConnection.State) -> QUICConnectionState {
        switch state {
        case .setup:
            return .setup
        case .preparing:
            return .preparing
        case .waiting(let error):
            return .waiting(error.asQUICPOSIXError())
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
    fileprivate func asQUICPOSIXError() -> POSIXError {
        switch self {
        case .posix(let code):
            return POSIXError(code)
        case .dns:
            return POSIXError(.EHOSTUNREACH, description: "QUIC DNS resolution failed: \(self)")
        case .tls:
            return POSIXError(.EPROTO, description: "QUIC TLS error: \(self)")
        case .wifiAware:
            return POSIXError(.ENETUNREACH, description: "QUIC Wi-Fi Aware error: \(self)")
        @unknown default:
            return POSIXError(.EIO, description: "QUIC network error: \(self)")
        }
    }
}

#endif // canImport(Network)
