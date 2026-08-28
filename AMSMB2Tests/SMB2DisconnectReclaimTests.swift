//
//  SMB2DisconnectReclaimTests.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//
//  Regression coverage for fix-disconnect-reclaims-context (GitHub issue #49).
//
//  `disconnect()` used to tear down the transport and fail pending operations without destroying
//  the `smb2_context`, so libsmb2 kept its `+1` on every pending `CBData` forever. Because the
//  `cb.dataHandler` wrappers captured the client strongly, that formed the cycle
//  `smb2_context.waitqueue → pdu.cb_data → CBData.dataHandler → SMB2Client → context`, making
//  `deinit` — the only caller of `smb2_destroy_context` — unreachable. These tests pin the fixed
//  contract: `disconnect()` reclaims the context and every pending callback object, and nothing
//  pending can keep the client alive.
//
//  This file is deliberately NOT inside `#if canImport(Network)`: the pending table and the
//  `async_await` path exist on the legacy fd platforms too, so the platform-neutral tests must
//  compile and run under `make linuxtest`. Only the seam-specific test is gated.
//

import Foundation
import SMB2
import XCTest

@testable import AMSMB2

final class SMB2DisconnectReclaimTests: XCTestCase, @unchecked Sendable {

    // MARK: - 1.1 — CBData.liveCount observability

    /// WHEN a `CBData` is created and then released
    /// THEN `CBData.liveCount` rises by one and returns to the baseline it had before.
    ///
    /// This is the mechanism every other test in this file asserts against, so it needs its own
    /// direct proof. Baseline-relative — other tests in the same process may hold live instances.
    func testCBDataLiveCountTracksInstances() throws {
        let baseline = SMB2Client.CBData.liveCount
        do {
            let cbData = SMB2Client.CBData()
            // `withExtendedLifetime` — not a dummy write — is what guarantees the instance is
            // still alive when the count is read; ARC may otherwise release it after its last use.
            withExtendedLifetime(cbData) {
                XCTAssertEqual(
                    SMB2Client.CBData.liveCount, baseline + 1,
                    "creating a CBData must increment the live count"
                )
            }
        }
        XCTAssertEqual(
            SMB2Client.CBData.liveCount, baseline,
            "releasing a CBData must return the live count to its baseline"
        )
    }

    // MARK: - 2.1 — disconnect() reclaims a pending operation's CBData and the client

    /// WHEN an operation has been queued to libsmb2 and no reply can arrive, and `disconnect()`
    /// is called
    /// THEN the waiting caller gets `ENOTCONN`, the callback object is released before
    /// `disconnect()` returns, and dropping the last strong reference deallocates the client.
    ///
    /// `smb2_echo_async` is used directly (bypassing `echo()`'s `isConnected` gate) because it has
    /// no session / transport / credit precondition — it just queues the PDU into `outqueue`,
    /// where it stays forever since no servicing path is armed on a never-connected client.
    ///
    /// `timeout: 0` is required: with a positive timeout `async_await` arms an
    /// `eventLoopQueue.asyncAfter` timer that captures `cb` STRONGLY, so the (already emptied)
    /// `CBData` shell could not deallocate until that timer fired, and the `liveCount` assertion
    /// immediately after `disconnect()` would be timing-dependent.
    func testDisconnectReleasesPendingCallbackObjectAndClient() async throws {
        let baseline = SMB2Client.CBData.liveCount
        var client: SMB2Client? = try SMB2Client(timeout: 0)
        // `weak var` + separate assignment: `weak let` needs Swift 6.2 (Linux CI is 6.1) and a
        // never-mutated `weak var` warns on 6.2.
        weak var weakClient: SMB2Client?
        weakClient = client

        // Capture the client strongly by value: Swift 6 forbids capturing the mutable `var` in a
        // @Sendable closure. The capture is released when the task completes, so the later
        // `client = nil` drops the last reference.
        let operationTask = Task { [client] in
            try await client!.async_await { context, cbPtr -> Int32 in
                smb2_echo_async(context, SMB2Client.generic_handler, cbPtr)
            }
        }

        let queued = await waitUntil(timeout: 5) { client!.pendingSeamOperationCount == 1 }
        XCTAssertTrue(queued, "the echo PDU must be registered in the pending table before disconnect")

        await client!.disconnect()

        do {
            _ = try await operationTask.value
            XCTFail("the pending operation must fail once the client is disconnected")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ENOTCONN, "a disconnected client must fail pending operations with ENOTCONN")
        } catch {
            XCTFail("Expected POSIXError(.ENOTCONN), got \(error)")
        }

        // `<=`, not `==`: the count is process-global and other suites leave 30 s timeout timers
        // holding emptied CBData shells, so it can legitimately drop BELOW the baseline captured
        // here. The intent is "this test leaked nothing", which is exactly `<= baseline`.
        XCTAssertLessThanOrEqual(
            SMB2Client.CBData.liveCount, baseline,
            "disconnect() must destroy the context so libsmb2 balances every pending CBData retain"
        )

        client = nil
        let released = await waitUntil(timeout: 2) { weakClient == nil }
        XCTAssertTrue(released, "no pending operation may keep the client alive after disconnect()")
    }

    // MARK: - 2.3 — disconnect() is terminal and later operations fail fast

    /// WHEN `disconnect()` has returned
    /// THEN the client reports no file descriptor and no connection, a subsequent operation
    /// throws `ENOTCONN` immediately rather than queuing a PDU into a transport-less context and
    /// hanging for the operation timeout, a second `disconnect()` returns, and releasing the
    /// client does not crash (the context is destroyed exactly once).
    ///
    /// A positive `timeout` is essential here: it is what makes the fail-fast assertion
    /// meaningful — before the fix the PDU queued into the still-live context and the caller
    /// hung for the full timeout before `ETIMEDOUT`.
    func testDisconnectIsTerminalAndLaterOperationsFailFast() async throws {
        var client: SMB2Client? = try SMB2Client(timeout: 30)
        // `weak var` + separate assignment: `weak let` needs Swift 6.2 (Linux CI is 6.1) and a
        // never-mutated `weak var` warns on 6.2.
        weak var weakClient: SMB2Client?
        weakClient = client

        await client!.disconnect()

        XCTAssertEqual(client!.fileDescriptor, -1, "a disconnected client must not report a live descriptor")
        XCTAssertFalse(client!.isConnected, "a disconnected client must not report itself connected")

        let start = Date()
        do {
            _ = try await client!.async_await { context, cbPtr -> Int32 in
                smb2_echo_async(context, SMB2Client.generic_handler, cbPtr)
            }
            XCTFail("an operation issued after disconnect() must fail")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ENOTCONN, "post-disconnect operations must fail with ENOTCONN")
        } catch {
            XCTFail("Expected POSIXError(.ENOTCONN), got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 5,
            "post-disconnect operations must fail fast, not hang until the operation timeout (\(elapsed)s)"
        )

        // Idempotence: a second disconnect must return promptly and must not destroy twice.
        await client!.disconnect()

        // Releasing the client must not crash: `deinit`'s `guard context != nil` skips a second
        // `smb2_destroy_context`, so the context is destroyed exactly once across both paths.
        client = nil
        let released = await waitUntil(timeout: 2) { weakClient == nil }
        XCTAssertTrue(released, "a disconnected client must deallocate once its last reference is dropped")
    }
}

#if canImport(Network)

// MARK: - 2.2 — seam connect pending at disconnect

extension SMB2DisconnectReclaimTests {

    /// WHEN a seam connect's NEGOTIATE is pending against a transport that never replies and
    /// `disconnect()` is called
    /// THEN the connect caller gets `ENOTCONN`, the pending table and the installed bridge are
    /// cleared, the connect's callback object is released, the external-transport retain libsmb2
    /// holds through `ext.userdata` is balanced (weak bridge is nil), and the client deallocates
    /// once the last strong reference is dropped.
    ///
    /// The `ext.userdata` `+1` (`TransportBridge.makeExternalTransport()`) is consumed ONLY by the
    /// C `ext.close` trampoline, which libsmb2 invokes from `smb2_destroy_context`. `teardownSeam()`
    /// calls the *Swift* `bridge.close()` and never reaches it — so before the fix `disconnect()`
    /// stranded the bridge and its transport as well as the `CBData`.
    ///
    /// `timeout: 0` — see `testDisconnectReleasesPendingCallbackObjectAndClient`: a positive
    /// timeout arms a timer that captures `cb` strongly, which would make the `liveCount`
    /// assertion timing-dependent.
    func testSeamDisconnectReleasesPendingConnectAndBridge() async throws {
        let baseline = SMB2Client.CBData.liveCount
        var client: SMB2Client? = try SMB2Client(timeout: 0)
        // `weak var` + separate assignment: `weak let` needs Swift 6.2 (Linux CI is 6.1) and a
        // never-mutated `weak var` warns on 6.2.
        weak var weakClient: SMB2Client?
        weakClient = client

        var bridge: TransportBridge? = TransportBridge(transport: MockTransport(sendsAreDropped: true))
        weak var weakBridge: TransportBridge?
        weakBridge = bridge

        let connectTask = Task { [client, bridge] in
            try await client!.connectWithBridge(
                server: "testserver", share: "testshare", user: "testuser",
                host: "testserver", port: 445,
                bridge: bridge!, selector: SMB2Client.seamSelector(for: .automatic)
            )
        }
        // Drop the test's own strong reference so the only remaining owners are the task capture
        // (released when the task completes) and libsmb2's `ext.userdata` retain.
        bridge = nil

        let queued = await waitUntil(timeout: 5) { client!.pendingSeamOperationCount == 1 }
        XCTAssertTrue(queued, "NEGOTIATE must be registered in the pending table before disconnect")

        await client!.disconnect()

        do {
            try await connectTask.value
            XCTFail("the pending connect must fail once the client is disconnected")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ENOTCONN, "a disconnected client must fail its pending connect with ENOTCONN")
        } catch {
            XCTFail("Expected POSIXError(.ENOTCONN), got \(error)")
        }

        XCTAssertEqual(client!.pendingSeamOperationCount, 0, "disconnect() must empty the pending table")
        XCTAssertFalse(client!.hasInstalledSeamBridge, "disconnect() must leave no installed seam bridge")
        // `<=` for the same process-global reason as in the async_await test above.
        XCTAssertLessThanOrEqual(
            SMB2Client.CBData.liveCount, baseline,
            "disconnect() must destroy the context so the abandoned connect CBData is released"
        )

        let bridgeReleased = await waitUntil(timeout: 2) { weakBridge == nil }
        XCTAssertTrue(
            bridgeReleased,
            "disconnect() must destroy the context so ext_close balances the ext.userdata retain on the bridge"
        )

        client = nil
        let released = await waitUntil(timeout: 2) { weakClient == nil }
        XCTAssertTrue(released, "no pending connect may keep the client alive after disconnect()")
    }
}

#endif // canImport(Network)
