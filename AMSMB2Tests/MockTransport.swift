//
//  MockTransport.swift
//  AMSMB2Tests
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  In-memory loopback `SMBTransport` double used by T4 unit tests and
//  reused by T5 bridge tests and T6 servicing tests.
//
//  Design notes:
//  - `actor` provides natural `Sendable` conformance and serialises all
//    state mutation, satisfying Swift 6 strict-concurrency requirements.
//  - `send(_:)` delivers bytes directly to a suspended `receive()` call
//    when one is waiting; otherwise it appends to the inbound queue.
//  - `receive()` uses `withTaskCancellationHandler` +
//    `withCheckedThrowingContinuation` so that a pending receive can be
//    unblocked when the enclosing `Task` is cancelled (never-reply mode).
//

import Foundation

@testable import AMSMB2

// MARK: - MockTransport

/// In-memory loopback transport for unit tests.
///
/// Bytes written via `send(_:)` are immediately available to `receive()`.
///
/// **Failure injection:**
/// - **Connect failure** — init with `connectBehavior: .fail(error)`.
/// - **Graceful EOF** — call `await signalGracefulEOF()` from a test task;
///   the next (or currently suspended) `receive()` returns empty `Data`.
/// - **Never-reply** — the default state when no bytes are queued and EOF
///   has not been signalled; `receive()` suspends until data arrives or the
///   enclosing `Task` is cancelled.
actor MockTransport: SMBTransport {

    // MARK: - Connect behaviour

    enum ConnectBehavior {
        case succeed
        case fail(any Error)
    }

    // MARK: - State

    private let connectBehavior: ConnectBehavior
    /// FIFO of chunks ready for the next `receive()` call.
    private var inboundQueue: [Data] = []
    /// Set by `signalGracefulEOF()`; causes an empty-queue `receive()` to return `Data()`.
    private var isEOF: Bool = false
    /// Set by `close()`; causes an empty-queue `receive()` to throw.
    private var isClosed: Bool = false
    /// A continuation waiting in `receive()` for the next chunk/EOF/close.
    private var waitingContinuation: CheckedContinuation<Data, any Error>?

    // MARK: - Init

    init(connectBehavior: ConnectBehavior = .succeed) {
        self.connectBehavior = connectBehavior
    }

    // MARK: - SMBTransport conformance

    func connect(host: String, port: Int) async throws {
        switch connectBehavior {
        case .succeed:
            break
        case .fail(let error):
            throw error
        }
    }

    func send(_ bytes: Data) async throws {
        guard !isClosed else { throw POSIXError(.ECONNRESET) }
        // Deliver directly to any suspended receive(), bypassing the queue.
        if let continuation = waitingContinuation {
            waitingContinuation = nil
            continuation.resume(returning: bytes)
        } else {
            inboundQueue.append(bytes)
        }
    }

    func receive() async throws -> Data {
        // Fast path: bytes already queued.
        if let chunk = inboundQueue.first {
            inboundQueue.removeFirst()
            return chunk
        }
        if isEOF { return Data() }
        if isClosed { throw POSIXError(.ECONNRESET) }

        // Slow path: suspend until send()/signalGracefulEOF()/close() wakes us.
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    // Check cancellation after the handler is registered but
                    // before storing the continuation, to close the race window
                    // where the onCancel handler fires before the continuation
                    // is stored (in which case onCancel is a noop and we'd leak
                    // the continuation).
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.waitingContinuation = continuation
                    }
                }
            },
            onCancel: { [self] in
                // onCancel runs on an unspecified executor — hop to the actor
                // to resume the stored continuation safely.
                Task { await self.resumeWaiting(throwing: CancellationError()) }
            }
        )
    }

    func close() async {
        isClosed = true
        resumeWaiting(throwing: POSIXError(.ECONNRESET))
    }

    // MARK: - Test helpers

    /// Signals graceful EOF.
    ///
    /// If `receive()` is currently suspended and the inbound queue is empty,
    /// it is resumed immediately with empty `Data`. Otherwise, the EOF flag is
    /// set and the next `receive()` call after the queue is drained will
    /// return empty `Data`.
    func signalGracefulEOF() {
        isEOF = true
        // Only wake a suspended receiver when the queue is drained — remaining
        // queued bytes must be consumed first (FIFO order).
        if inboundQueue.isEmpty {
            resumeWaiting(with: .success(Data()))
        }
    }

    // MARK: - Private helpers

    private func resumeWaiting(throwing error: any Error) {
        resumeWaiting(with: .failure(error))
    }

    private func resumeWaiting(with result: Result<Data, any Error>) {
        guard let continuation = waitingContinuation else { return }
        waitingContinuation = nil
        continuation.resume(with: result)
    }
}
