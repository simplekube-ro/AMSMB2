//
//  BridgeOwnershipHandoffTests.swift
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

// MARK: - Transition-table unit tests (deterministic, no cancellation timing)

final class BridgeOwnershipHandoffTests: XCTestCase, @unchecked Sendable {
    typealias Handoff = BridgeOwnershipHandoff

    // MARK: Reconciliation rows A–D

    /// Row A — success while `eagerConnecting` → `localOwned`, proceed, no close.
    func testReconcileRowASuccessProceeds() {
        let handoff = Handoff()
        XCTAssertEqual(handoff.reconcile(connectFailed: false), .proceed)
        XCTAssertEqual(handoff.currentState, .localOwned)
    }

    /// Row D — any failure while `eagerConnecting` → `finished`, eagerFailed (mapped original
    /// error rethrown by the caller), close exactly once.
    func testReconcileRowDFailureFinishes() {
        let handoff = Handoff()
        XCTAssertEqual(handoff.reconcile(connectFailed: true), .eagerFailed)
        XCTAssertEqual(handoff.currentState, .finished)
    }

    /// Row B — success while `cancelled` (e.g. QUIC `.ready` won after outer cancellation) →
    /// consumed to `finished`, cancellationWon (close once, CancellationError).
    func testReconcileRowBSuccessAfterCancel() {
        let handoff = Handoff()
        XCTAssertEqual(handoff.cancel(), .noClose) // eagerConnecting → cancelled
        XCTAssertEqual(handoff.currentState, .cancelled)
        XCTAssertEqual(handoff.reconcile(connectFailed: false), .cancellationWon)
        XCTAssertEqual(handoff.currentState, .finished)
    }

    /// Row C — cancellation-shaped (or any) failure while `cancelled` → consumed to `finished`,
    /// cancellationWon (normalized to CancellationError).
    func testReconcileRowCFailureAfterCancel() {
        let handoff = Handoff()
        XCTAssertEqual(handoff.cancel(), .noClose)
        XCTAssertEqual(handoff.reconcile(connectFailed: true), .cancellationWon)
        XCTAssertEqual(handoff.currentState, .finished)
    }

    // MARK: Race E — cancellation vs ordinary eager failure, both commit orders

    /// Commit order 1 — cancellation commits `eagerConnecting → cancelled` BEFORE the
    /// reconciliation claim: cancellation is caller-visible (cancellationWon) even though the
    /// eager connect failed.
    func testRaceECancellationCommitsFirst() {
        let handoff = Handoff()
        _ = handoff.cancel() // cancellation first
        XCTAssertEqual(handoff.reconcile(connectFailed: true), .cancellationWon)
    }

    /// Commit order 2 — the reconciliation claim runs on the failure BEFORE cancellation: the
    /// transport failure is caller-visible (eagerFailed); the later `onCancel` finds `finished`
    /// and is a no-op (`.noClose`), so exactly one close happens either way.
    func testRaceEFailureCommitsFirst() {
        let handoff = Handoff()
        XCTAssertEqual(handoff.reconcile(connectFailed: true), .eagerFailed) // failure first
        XCTAssertEqual(handoff.cancel(), .noClose) // late onCancel: no-op
        XCTAssertEqual(handoff.currentState, .finished)
    }

    // MARK: Cancel while localOwned + failed install claim

    /// Cancel while `localOwned`: `onCancel` closes exactly once (`closeLocalBridge`) and the
    /// install block's subsequent `installing` claim FAILS — so it creates nothing and makes no
    /// libsmb2 call (structural proof of the "failed claim invokes neither the callback-pointer
    /// factory nor makeExternalTransport()" requirement).
    func testCancelWhileLocalOwnedThenFailedInstallClaim() {
        let handoff = Handoff()
        XCTAssertEqual(handoff.reconcile(connectFailed: false), .proceed) // → localOwned
        XCTAssertEqual(handoff.cancel(), .closeLocalBridge) // localOwned → cancelled
        XCTAssertEqual(handoff.currentState, .cancelled)
        XCTAssertFalse(handoff.claimInstalling(), "a failed install claim must not proceed")
        XCTAssertEqual(handoff.currentState, .cancelled)
    }

    // MARK: Cancel racing the installing claim (exactly one winner)

    /// Install claim wins first (`localOwned → installing`): a later `onCancel` routes through the
    /// installed-ownership teardown (`installedTeardown`), never a second local close.
    func testInstallClaimWinsThenCancelRoutesToInstalledTeardown() {
        let handoff = Handoff()
        _ = handoff.reconcile(connectFailed: false) // → localOwned
        XCTAssertTrue(handoff.claimInstalling()) // → installing
        XCTAssertEqual(handoff.cancel(), .installedTeardown)
        // markInstalled then a late cancel still routes to installed teardown.
        handoff.markInstalled()
        XCTAssertEqual(handoff.currentState, .installed)
        XCTAssertEqual(handoff.cancel(), .installedTeardown)
    }

    /// Cancellation wins first (`localOwned → cancelled`): the install claim then fails, so no
    /// libsmb2 connect work begins — exactly one winner.
    func testCancelWinsThenInstallClaimFails() {
        let handoff = Handoff()
        _ = handoff.reconcile(connectFailed: false) // → localOwned
        XCTAssertEqual(handoff.cancel(), .closeLocalBridge) // cancellation wins
        XCTAssertFalse(handoff.claimInstalling()) // loser: no install
    }

    // MARK: Install-failure transition + terminal idempotence

    /// An install-block failure path consumes ownership (`installing → finished`); a later
    /// `onCancel` is then a bridge no-op (`noClose`).
    func testMarkFinishedMakesLateCancelNoOp() {
        let handoff = Handoff()
        _ = handoff.reconcile(connectFailed: false)
        _ = handoff.claimInstalling() // → installing
        handoff.markFinished() // → finished
        XCTAssertEqual(handoff.currentState, .finished)
        XCTAssertEqual(handoff.cancel(), .noClose)
    }

    /// Idempotence: repeated `cancel()` from a terminal state never re-assigns a close duty.
    func testRepeatedCancelFromTerminalIsNoOp() {
        let handoff = Handoff()
        _ = handoff.cancel() // eagerConnecting → cancelled
        _ = handoff.reconcile(connectFailed: false) // cancelled → finished
        XCTAssertEqual(handoff.cancel(), .noClose)
        XCTAssertEqual(handoff.cancel(), .noClose)
        XCTAssertEqual(handoff.currentState, .finished)
    }
}

// MARK: - Wired connectWithBridge tests (MockTransport / gated transport)

final class BridgeOwnershipConnectTests: XCTestCase, @unchecked Sendable {
    /// Ordinary eager failure (row D): the mapped original transport error surfaces — never
    /// `CancellationError` — the bridge closes exactly once, and no seam is installed.
    func testOrdinaryEagerFailureSurfacesMappedError() async throws {
        let client = try SMB2Client(timeout: 30)
        let transport = GatedOutcomeTransport(outcome: .fail(POSIXError(.ECONNREFUSED)), gated: false)
        let bridge = TransportBridge(transport: transport)

        do {
            try await client.connectWithBridge(
                server: "testserver", share: "s", user: "u",
                host: "testserver", port: 445,
                bridge: bridge, selector: SMB2Client.seamSelector(for: .automatic)
            )
            XCTFail("ordinary eager failure must throw")
        } catch is CancellationError {
            XCTFail("row D must surface the mapped transport error, not CancellationError")
        } catch let posix as POSIXError {
            XCTAssertEqual(posix.code, .ECONNREFUSED, "the mapped original error must propagate")
        }

        try await assertCleanNonInstalledState(client, transport, label: "ordinary failure")
    }

    /// TCP-shaped eager cancellation (row C): cancellation wins, the transport throws its internal
    /// `POSIXError(.ECANCELED)`, and the caller observes `CancellationError` (normalized) with the
    /// bridge closed exactly once and nothing installed.
    func testTCPShapedEagerCancellationNormalizesToCancellationError() async throws {
        try await assertCancellationWin(
            outcome: .fail(POSIXError(.ECANCELED)), label: "TCP-shaped ECANCELED"
        )
    }

    /// QUIC-shaped ready-after-cancel (row B): the transport connect succeeds despite outer
    /// cancellation (`.ready` won its internal claim), yet the caller still observes
    /// `CancellationError` with the bridge closed exactly once and nothing installed.
    func testQUICShapedReadyAfterCancelSurfacesCancellationError() async throws {
        try await assertCancellationWin(outcome: .succeed, label: "QUIC-shaped ready-after-cancel")
    }

    /// Cancel while the bridge is `localOwned` (eager connect returned success, install block has
    /// NOT yet claimed): `onCancel` closes the still-local bridge exactly once, and the install
    /// block's later `installing` claim FAILS — so no libsmb2 install happens and the caller
    /// observes `CancellationError`. Closes the end-to-end gap that the transition-table test
    /// covered only at the type level.
    func testCancelAtLocalOwnedSurfacesCancellationErrorWithoutInstall() async throws {
        let client = try SMB2Client(timeout: 30)
        let transport = GatedOutcomeTransport(outcome: .succeed, gated: true)
        let bridge = TransportBridge(transport: transport)

        // Occupy the serial event-loop queue so the install block (dispatched there) cannot claim
        // `installing` until we release it. FIFO ordering guarantees this barrier — enqueued
        // before the connect task starts — runs ahead of the install block, pinning the cancel to
        // the `localOwned` window.
        let barrier = DispatchSemaphore(value: 0)
        client.eventLoopQueue.async { barrier.wait() }

        let task = Task {
            try await client.connectWithBridge(
                server: "testserver", share: "s", user: "u",
                host: "testserver", port: 445,
                bridge: bridge, selector: SMB2Client.seamSelector(for: .automatic)
            )
        }

        // Let the eager connect complete so reconciliation transitions to `localOwned`; the
        // install block then queues behind the barrier and the task suspends at the continuation.
        await transport.waitUntilConnecting()
        await transport.openGate()
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms: allow the sync reconcile to run.

        // Cancel while the bridge is locally owned and the install block is still blocked, then
        // release the queue so the install block runs its failed `installing` claim.
        task.cancel()
        barrier.signal()

        do {
            try await task.value
            XCTFail("cancel at localOwned must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("cancel at localOwned must surface CancellationError, got \(error)")
        }

        try await assertCleanNonInstalledState(client, transport, label: "cancel-at-localOwned")
    }

    // MARK: - Helpers

    /// Drives a gated transport whose eager connect completes with `outcome` only AFTER the task
    /// has been cancelled (so `onCancel` deterministically commits `eagerConnecting → cancelled`
    /// before the eager-completion reconciliation runs). Asserts the caller sees
    /// `CancellationError`, the bridge closed exactly once, and no seam was installed.
    private func assertCancellationWin(
        outcome: GatedOutcomeTransport.Outcome, label: String
    ) async throws {
        let client = try SMB2Client(timeout: 30)
        let transport = GatedOutcomeTransport(outcome: outcome, gated: true)
        let bridge = TransportBridge(transport: transport)

        let task = Task {
            try await client.connectWithBridge(
                server: "testserver", share: "s", user: "u",
                host: "testserver", port: 445,
                bridge: bridge, selector: SMB2Client.seamSelector(for: .automatic)
            )
        }

        // Ensure the eager connect is parked inside the cancellation scope, then cancel so
        // `onCancel` commits `cancelled` before we release the gate.
        await transport.waitUntilConnecting()
        task.cancel()
        await transport.openGate()

        do {
            try await task.value
            XCTFail("[\(label)] cancellation win must throw")
        } catch is CancellationError {
            // Expected — normalized regardless of the transport's internal outcome.
        } catch {
            XCTFail("[\(label)] cancellation win must surface CancellationError, got \(error)")
        }

        try await assertCleanNonInstalledState(client, transport, label: label)
    }

    /// Common post-conditions for every cancellation/eager-failure win: the bridge closed exactly
    /// once, no seam bridge installed, and no pending seam operation left registered.
    private func assertCleanNonInstalledState(
        _ client: SMB2Client, _ transport: GatedOutcomeTransport, label: String
    ) async throws {
        // bridge.close() fires transport.close() from a detached Task — await it settling to 1.
        try await waitForCloseCount(transport, equals: 1, label: label)
        XCTAssertFalse(
            client.hasInstalledSeamBridge, "[\(label)] no seam bridge must be installed"
        )
        XCTAssertEqual(
            client.pendingSeamOperationCount, 0, "[\(label)] no pending seam operation"
        )
        XCTAssertFalse(client.isConnected, "[\(label)] client must not be seam-connected")
    }

    /// Polls the transport's async close counter until it reaches `expected` (bounded), proving
    /// exactly-once close without depending on Task scheduling timing.
    private func waitForCloseCount(
        _ transport: GatedOutcomeTransport, equals expected: Int, label: String
    ) async throws {
        for _ in 0..<200 {
            if await transport.closeCount == expected {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000) // 5 ms
        }
        let count = await transport.closeCount
        XCTAssertEqual(count, expected, "[\(label)] bridge.close() must run exactly \(expected)x")
    }
}

// MARK: - Gated outcome transport (test double)

/// A controllable `SMBTransport` whose eager `connect` parks (when `gated`) until `openGate()` and
/// then completes with a configured `outcome`, and whose `close()` invocations are counted. It
/// never delivers anything inbound, so the receiver it is handed is ignored. Lets
/// tests drive the D12 cancellation-versus-eager-completion races deterministically: cancel the
/// task while `connect` is parked, then release the gate to complete the connect after
/// cancellation has won the handoff.
actor GatedOutcomeTransport: SMBTransport {
    enum Outcome: Sendable {
        case succeed
        case fail(any Error)
    }

    private let outcome: Outcome
    private var gateOpened: Bool
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var isConnecting = false
    private var connectingWaiter: CheckedContinuation<Void, Never>?
    private(set) var closeCount = 0

    init(outcome: Outcome, gated: Bool) {
        self.outcome = outcome
        self.gateOpened = !gated
    }

    func connect(
        host _: String, port _: Int,
        onReceive _: @escaping InboundReceiver
    ) async throws {
        isConnecting = true
        connectingWaiter?.resume()
        connectingWaiter = nil

        if !gateOpened {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                gateContinuation = cont
            }
        }
        switch outcome {
        case .succeed:
            return
        case .fail(let error):
            throw error
        }
    }

    func send(_: Data) async throws {}

    func close() async {
        closeCount += 1
    }

    // MARK: Test control

    /// Resumes once `connect` has begun parking on the gate.
    func waitUntilConnecting() async {
        if isConnecting {
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if isConnecting {
                cont.resume()
            } else {
                connectingWaiter = cont
            }
        }
    }

    /// Releases a parked `connect` so it completes with the configured outcome.
    func openGate() {
        gateOpened = true
        gateContinuation?.resume()
        gateContinuation = nil
    }
}

#endif // canImport(Network)
