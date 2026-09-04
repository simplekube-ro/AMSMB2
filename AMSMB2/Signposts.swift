//
//  Signposts.swift
//  AMSMB2
//
//  Copyright © 2024 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

#if canImport(Network)

import Foundation
import os.signpost

// MARK: - InboundSignposts

/// `os_signpost` emission points for the SMB-over-NIO inbound path (design D1/D2).
///
/// The five points — `TransportRead`, `InboundChunk`, `ServiceDispatch`, `ServicePass` and
/// `RecvDrain` — make the inbound path's hand-offs measurable: the `TransportRead →
/// InboundChunk` gap is the in-callback hand-off into the bridge (the lock and the FIFO append,
/// on the transport's own delivery queue), and `ServiceDispatch` is the one executor hop that
/// remains — the debounce plus the event-loop queue. Before the inbound push-conversion (#45) a
/// cooperative-pool `Task` sat between those two events and the gap was its executor hop; the
/// baseline in `docs/PROFILING.md` records what that cost.
///
/// **Reentrancy.** `os_signpost` never calls back into AMSMB2 code, so an emit inside
/// `SMB2Client.serviceFlagLock` or `TransportBridge.lock` cannot re-enter either lock; there is
/// no lock-ordering or reentrancy hazard. When nothing is recording, the cost of an emission
/// point is one enablement check — the guard is what keeps Swift from
/// building the `[any CVarArg]` vararg array inside those critical sections. While a recorder is
/// attached the cost is a bounded, non-blocking write into the signpost buffer.
///
/// `os_signpost`, `OSSignpostID` and the enablement check are available at every deployment
/// floor of this package, so no `if #available` branch sits in the hot path.
enum InboundSignposts {
    /// Subsystem an operator filters the `os_signpost` instrument to; pinned to
    /// `docs/PROFILING.md` by `SignpostContractTests`.
    static let subsystem = "ro.SimpleKube.AMSMB2"

    /// Category an operator filters the `os_signpost` instrument to; pinned to
    /// `docs/PROFILING.md` by `SignpostContractTests`.
    static let category = "Inbound"

    // Signpost names. These are the join key between the emitting code, the metrics table in
    // `docs/PROFILING.md` and the parser in `scripts/profile-summary.sh`: a rename on one side
    // alone makes the summary report `count 0`, indistinguishable from "that point never fired".
    // `SignpostContractTests` pins all three sides together.

    static let transportReadName: StaticString = "TransportRead"
    static let chunkName: StaticString = "InboundChunk"
    static let recvDrainName: StaticString = "RecvDrain"
    static let serviceDispatchName: StaticString = "ServiceDispatch"
    static let servicePassName: StaticString = "ServicePass"

    /// Shared log handle. `OSLog` is thread-safe and may be used from any queue.
    static let log = OSLog(subsystem: subsystem, category: category)

    // MARK: Events

    /// A chunk arrived from the network stack, on the network stack's own queue (TCP only).
    static func transportRead(bytes: Int) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .event, log: log, name: transportReadName, signpostID: .exclusive,
            "bytes=%ld", bytes
        )
    }

    /// A non-empty inbound chunk was delivered to the bridge's FIFO — emitted inside the same
    /// transport callback as its `TransportRead`, so the two pair one-to-one (zero-length reads
    /// are skipped before `TransportRead` is emitted, so no chunk is ever empty).
    static func chunk(bytes: Int) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .event, log: log, name: chunkName, signpostID: .exclusive, "bytes=%ld", bytes
        )
    }

    /// libsmb2 drained the inbound store: `bytes` were copied, or `0` for EOF.
    static func recv(bytes: Int) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .event, log: log, name: recvDrainName, signpostID: .exclusive, "bytes=%ld", bytes
        )
    }

    /// libsmb2 drained the inbound store and found it empty: the would-block marker, encoded as
    /// `-1` so it is distinguishable from the `0` that means EOF.
    static func recvWouldBlock() {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .event, log: log, name: recvDrainName, signpostID: .exclusive, "bytes=%ld", -1
        )
    }

    // MARK: Intervals

    /// An inbound-ready signal armed a service pass. Paired with ``dispatchEnd(for:)``.
    static func dispatchBegin(for object: AnyObject) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .begin, log: log, name: serviceDispatchName,
            signpostID: OSSignpostID(log: log, object: object)
        )
    }

    /// The armed signal was cleared — the pass began, or teardown got there first.
    static func dispatchEnd(for object: AnyObject) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .end, log: log, name: serviceDispatchName,
            signpostID: OSSignpostID(log: log, object: object)
        )
    }

    /// A signal-driven service pass started on the event-loop queue.
    static func passBegin(for object: AnyObject) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .begin, log: log, name: servicePassName,
            signpostID: OSSignpostID(log: log, object: object)
        )
    }

    /// A service pass ended. `terminal` records that the seam was gone when it ended, so the
    /// summary tooling can keep teardown-carrying passes out of the duration percentiles.
    static func passEnd(for object: AnyObject, terminal: Bool) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .end, log: log, name: servicePassName,
            signpostID: OSSignpostID(log: log, object: object),
            "terminal=%ld", terminal ? 1 : 0
        )
    }
}

#endif // canImport(Network)
