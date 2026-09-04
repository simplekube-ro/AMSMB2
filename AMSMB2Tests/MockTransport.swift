//
//  MockTransport.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  In-memory push `SMBTransport` double used by T4 unit tests and
//  reused by T5 bridge tests and T6 servicing tests.
//
//  Design notes:
//  - `actor` provides natural `Sendable` conformance and serialises all
//    state mutation, satisfying Swift 6 strict-concurrency requirements.
//  - Inbound is injected by the test (`deliver`, `signalGracefulEOF`,
//    `signalError`) and pushed straight to the handler supplied at connect —
//    synchronously, so a test can assert on the bridge's state the moment the
//    injection call returns.
//  - Outbound is observed, never looped back: `send(_:)` appends to a sent log
//    readable through `sentChunks()` / `waitForSent(count:)`. The old loopback
//    fed libsmb2 its own PDUs back as "server responses" (which SIGSEGV'd its
//    parser), which is why it needed a drop-sends escape hatch; with the two
//    directions separated, neither exists any more.
//

import Foundation

@testable import AMSMB2

// MARK: - MockTransport

/// In-memory push transport for unit tests.
///
/// **Inbound injection:**
/// - **Chunk** — `await mock.deliver(bytes)`.
/// - **Graceful EOF** — `await mock.signalGracefulEOF()` (empty `Data`, terminal).
/// - **Abnormal loss** — `await mock.signalError(error)` (terminal).
/// - **Never-reply** — the default: inject nothing.
///
/// **Outbound observation:** `await mock.sentChunks()`, `await mock.waitForSent(count:)`.
///
/// **Failure injection:** init with `connectBehavior: .fail(error)`; such a `connect` throws
/// and never installs (or invokes) the handler it was given.
actor MockTransport: SMBTransport {

    // MARK: - Connect behaviour

    enum ConnectBehavior {
        case succeed
        case fail(any Error)
    }

    // MARK: - State

    private let connectBehavior: ConnectBehavior
    /// The receiver supplied to `connect(host:port:onReceive:)`. `nil` before a successful
    /// connect and after `close()`.
    private var onReceive: InboundReceiver?
    /// Set once EOF or an error has been delivered — both are terminal.
    private var deliveryTerminated = false
    /// Set by `close()`; suppresses every further delivery and fails `send(_:)`.
    private var isClosed = false
    /// Every payload passed to `send(_:)`, in send order.
    private var sent: [Data] = []
    /// Continuations parked in `waitForSent(count:)` until the log reaches their count.
    private var sentWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    // MARK: - Init

    init(connectBehavior: ConnectBehavior = .succeed) {
        self.connectBehavior = connectBehavior
    }

    // MARK: - SMBTransport conformance

    func connect(
        host: String, port: Int,
        onReceive: @escaping InboundReceiver
    ) async throws {
        switch connectBehavior {
        case .succeed:
            // Installed only on the success path: a throwing connect never invokes its handler.
            self.onReceive = onReceive
        case .fail(let error):
            throw error
        }
    }

    func send(_ bytes: Data) async throws {
        guard !isClosed else { throw POSIXError(.ECONNRESET) }
        sent.append(bytes)
        resumeSentWaiters()
    }

    func close() async {
        isClosed = true
        deliveryTerminated = true
        onReceive = nil
        // Never leave a test parked on a count the closed mock can no longer reach.
        resumeAllSentWaiters()
    }

    // MARK: - Test helpers: inbound injection

    /// Delivers `bytes` as one inbound chunk.
    func deliver(_ bytes: Data) {
        emit(.success(bytes))
    }

    /// Delivers graceful EOF (empty `Data`). Terminal.
    func signalGracefulEOF() {
        emit(.success(Data()))
    }

    /// Delivers abnormal connection loss. Terminal.
    func signalError(_ error: POSIXError) {
        emit(.failure(error))
    }

    // MARK: - Test helpers: outbound observation

    /// Every payload passed to `send(_:)`, in send order.
    func sentChunks() -> [Data] {
        sent
    }

    /// Suspends until at least `count` payloads have been sent (or the mock is closed).
    func waitForSent(count: Int) async {
        guard sent.count < count, !isClosed else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sentWaiters.append((count, continuation))
        }
    }

    // MARK: - Private helpers

    /// The single delivery path: nothing after `close()`, nothing after a terminal delivery.
    private func emit(_ result: Result<Data, POSIXError>) {
        guard !isClosed, !deliveryTerminated, let handler = onReceive else { return }
        switch result {
        case .success(let data) where data.isEmpty:
            deliveryTerminated = true
        case .failure:
            deliveryTerminated = true
        case .success:
            break
        }
        handler(result)
    }

    private func resumeSentWaiters() {
        let reached = sentWaiters.filter { $0.count <= sent.count }
        sentWaiters.removeAll { $0.count <= sent.count }
        for waiter in reached {
            waiter.continuation.resume(returning: ())
        }
    }

    private func resumeAllSentWaiters() {
        let parked = sentWaiters
        sentWaiters = []
        for waiter in parked {
            waiter.continuation.resume(returning: ())
        }
    }
}
