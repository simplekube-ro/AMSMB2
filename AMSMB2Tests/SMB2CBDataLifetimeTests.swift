//
//  SMB2CBDataLifetimeTests.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Regression coverage for fix-cbdata-cancel-race-uaf.
//
//  These tests pin the CBData memory-ownership contract: once a PDU is queued, libsmb2 owns
//  `cbPtr` and fires `generic_handler` exactly once (on the reply or during
//  `smb2_destroy_context`'s teardown sweep), which performs the single balancing
//  `takeRetainedValue()`. A cancellation observed *after* the PDU is queued must NOT release the
//  retain — doing so double-balances and frees CBData out from under an in-flight operation,
//  producing a use-after-free when the late callback runs.
//

#if canImport(Network)

import Foundation
import XCTest

@testable import AMSMB2

final class SMB2CBDataLifetimeTests: XCTestCase, @unchecked Sendable {

    // MARK: - Gated test transport

    /// A test transport whose `connect(host:port:)` SUSPENDS on a stored continuation until the
    /// test calls `openGate()`. This lets the test cancel the driving `Task` while it is parked
    /// inside `bridge.connect()`, then release the gate so `connectWithBridge` proceeds into an
    /// already-cancelled `withTaskCancellationHandler` — deterministically driving the post-queue
    /// abandoned branch (Context.swift connectWithBridge, after `smb2_connect_share_async`).
    ///
    /// IMPORTANT: `connect` is intentionally NOT cancellation-aware — it returns NORMALLY when the
    /// gate opens even if the task was already cancelled. If it threw `CancellationError` instead,
    /// the `do/catch` around `bridge.connect()` would intercept it and the target branch would
    /// never be reached.
    actor GatedConnectTransport: SMBTransport {

        /// Continuation `connect` parks on until `openGate()` resumes it.
        private var gateContinuation: CheckedContinuation<Void, Never>?
        /// Set by `openGate()`; covers the race where the gate opens before `connect` parks.
        private var gateOpened = false

        /// Set once `connect` has begun (before it parks).
        private var isConnecting = false
        /// Waiter resumed when `connect` begins, backing `waitUntilConnecting()`.
        private var connectingWaiter: CheckedContinuation<Void, Never>?

        private var isClosed = false

        // MARK: SMBTransport conformance

        func connect(
            host: String, port: Int,
            onReceive _: @escaping InboundReceiver
        ) async throws {
            // Signal that connect has begun, before parking, so `waitUntilConnecting()` unblocks.
            isConnecting = true
            if let waiter = connectingWaiter {
                connectingWaiter = nil
                waiter.resume()
            }
            // If the gate is already open, return immediately.
            guard !gateOpened else { return }
            // Park until openGate() resumes us. Non-throwing: returns NORMALLY even if the
            // enclosing Task was cancelled while we were parked here (by design — see above).
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.gateContinuation = continuation
            }
        }

        func send(_ bytes: Data) async throws {
            // Drop bytes: never loop libsmb2's own NEGOTIATE PDU back as a "server response"
            // (which would SIGSEGV libsmb2's parser). The receiver is never invoked either —
            // this double models a server that accepts the connection and then says nothing.
        }

        func close() async {
            isClosed = true
        }

        // MARK: Test gate helpers

        /// Suspends until `connect(host:port:)` has begun (and is therefore parked on the gate).
        func waitUntilConnecting() async {
            guard !isConnecting else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.connectingWaiter = continuation
            }
        }

        /// Opens the gate, resuming a parked `connect` so it returns normally.
        func openGate() {
            gateOpened = true
            if let continuation = gateContinuation {
                gateContinuation = nil
                continuation.resume()
            }
        }
    }

    // MARK: - Post-queue cancellation must not free CBData

    /// WHEN a seam `connectWithBridge` task is cancelled in the window after
    /// `smb2_connect_share_async` queued NEGOTIATE but before the setup block stored the
    /// continuation (so `onCancel` sets `cb.isAbandoned` ahead of the setup block on the serial
    /// event-loop queue, making the setup block hit the abandoned branch)
    /// THEN the operation resumes with `CancellationError`, the pending table is empty, the client
    /// is not connected, AND subsequent client teardown (`deinit` → `smb2_destroy_context`) does
    /// NOT crash — because the CBData retain is left for `generic_handler`'s single balancing
    /// `takeRetainedValue()` rather than being released here.
    ///
    /// This executes the GENUINE production connectWithBridge post-queue abandoned branch.
    ///
    /// REGRESSION POINT: with the OLD code (`Unmanaged<CBData>.fromOpaque(cbPtr).release()` on the
    /// abandoned branch) the retain is balanced twice — once here and once by the
    /// `generic_handler` libsmb2 fires for the orphaned NEGOTIATE PDU during
    /// `smb2_destroy_context` at `deinit` — so `takeRetainedValue()` runs on freed memory: a
    /// use-after-free. With the fix the retain is balanced exactly once and teardown is clean.
    ///
    /// Determinism / sanitizer note: the cancellation ordering is forced deterministically (gate +
    /// already-cancelled `withTaskCancellationHandler`). The UAF itself is a freed-memory access;
    /// without AddressSanitizer it may not crash on every run, but under
    /// `--sanitize=address` it is a hard, reliable failure. The test always runs the real branch.
    func testCancelledSeamConnectAfterQueueDoesNotUseAfterFreeOnTeardown() async throws {
        var client: SMB2Client? = try SMB2Client(timeout: 30)
        let transport = GatedConnectTransport()
        let bridge = TransportBridge(transport: transport)

        // Capture the client strongly by value (Swift 6 forbids capturing the mutable `var` in a
        // @Sendable closure). Once the task completes, this capture is released, so the later
        // `client = nil` drops the last reference and triggers deinit deterministically.
        let task = Task { [client] in
            try await client!.connectWithBridge(
                server: "testserver", share: "testshare", user: "testuser",
                host: "testserver", port: 445,
                bridge: bridge, selector: SMB2Client.seamSelector(for: .automatic)
            )
        }

        // Wait until connect is parked on the gate, then cancel while it is suspended.
        await transport.waitUntilConnecting()
        task.cancel()
        // Open the gate: connect returns normally; connectWithBridge then enters an
        // already-cancelled withTaskCancellationHandler → onCancel enqueues isAbandoned=true on the
        // serial eventLoopQueue ahead of the setup block → setup block hits the abandoned branch
        // AFTER smb2_connect_share_async queued NEGOTIATE.
        await transport.openGate()

        do {
            try await task.value
            XCTFail("Expected CancellationError after Task.cancel()")
        } catch is CancellationError {
            // Expected: the post-queue abandoned branch resumed with CancellationError.
        } catch {
            XCTFail("Cancellation must surface as CancellationError, got \(error)")
        }

        XCTAssertEqual(client!.pendingSeamOperationCount, 0,
            "the cancelled seam operation must not remain in the pending table")
        XCTAssertFalse(client!.isConnected,
            "a cancelled connect must not leave the client seam-connected")

        // Regression assertion: drop the last reference. deinit → eventLoopQueue.sync { shutdown() }
        // → smb2_destroy_context fires the orphaned NEGOTIATE's connect-cb chain → generic_handler →
        // takeRetainedValue. Under the OLD code this is a use-after-free (the retain was already
        // released on the abandoned branch); under the fix it balances the single surviving retain
        // cleanly. Reliably caught under AddressSanitizer.
        client = nil
    }
}

#endif // canImport(Network)
