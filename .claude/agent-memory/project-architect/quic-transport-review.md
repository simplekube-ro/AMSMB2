---
name: quic-transport-review
description: Verified facts + findings from the add-quic-transport pre-apply review (close/EOF semantics, policy plumbing, Linux inertness)
metadata:
  type: project
---

Pre-apply review of `add-quic-transport` (AMSMB2 #29 / RandomPlayer #346), verdict approve-with-changes on 2026-07-24.

**Why:** SMB-over-QUIC (NWProtocolQUIC, ALPN "smb", single bidi stream byte-pipe, opt-in, UDP/443, DNS-name-only, secure-by-default) slotting into the existing seam with no libsmb2/TransportBridge changes.

**Verified code facts (reusable for future transport reviews):**
- `TCPTransportApple.close()` resumes a parked `receive()` waiter with **empty `Data()` (graceful EOF)** via `InboundBufferingHandler.signalClosed()`, NOT with an error. `receive()` after close also returns empty `Data()`. `POSIXError(.ENOTCONN)` is thrown only in the **never-connected** case (`_channel == nil`), not the closed-after-open case. So any "mirror TCP: close fails waiter with ENOTCONN" claim is FALSE.
- `TransportBridge.inboundPump()` distinguishes: `receive()` returns empty → `setInboundEOF()` → `cRecv` returns 0 (graceful); `receive()` throws → `setInboundError()` → `cRecv` returns -1/ECONNRESET (abnormal). So EOF-vs-error at the transport IS observable through the bridge.
- `parseSeamEndpoint(_ server:)` is `static`, hardcodes port 445, and is called **inside `connectWithBridge`** — which does NOT receive the `SMBTransportKind`. The kind is only known in `connect(server:share:user:transportKind:)` (Context.swift ~1120). Any per-kind port default (443) or post-parse IP-rejection needs the parse hoisted into the kind-aware wrapper or the kind threaded into connectWithBridge.
- `SMBTransportKind` (SMBTransport.swift:62) has NO raw value (`Sendable, Equatable, Hashable` only). "Encode as string rawValue" requires adding `: String`/RawRepresentable to the public enum.
- On Linux (`#else`, no `canImport(Network)`), `SMB2Manager.connect(shareName:encrypted:)` calls the legacy `connect(server:share:user:)` and ignores `transportKind` entirely — a new public `transportKind` property would be inert there; `.quic` would silently become legacy TCP.
- The availability-below-floor `ENOTSUP` path is not unit-testable via `#available` on CI hosts (macOS 12+ floor, CI runs newer) without an injectable availability seam.

**How to apply:** When reviewing conformers added under the seam, check close/EOF parity against TCPTransportApple and the bridge's EOF-vs-error mapping; confirm policy plumbing has access to the kind at the parse site; confirm Linux behavior of any new public transport property.
