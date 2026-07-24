# Tasks: add-quic-transport

TDD applies throughout: each task starts by writing/updating the tests for its spec scenarios
(`swift test --disable-sandbox`), then the minimum implementation, then refactor.

## 1. Connection policy (pure logic first — fully unit-testable, no network)

- [ ] 1.1 Tests for IP-literal detection (IPv4, IPv6, bracketed IPv6, valid DNS names) and the
      `.quic` `EINVAL` rejection path; then implement host validation in
      `SMB2Client.connect(transportKind:)` (`quic-connection-policy` spec)
- [ ] 1.2 Tests for per-kind default port (445 tcp/automatic, 443 quic, explicit port honored);
      then the design-D4 plumbing restructure: add `defaultPort:` to `parseSeamEndpoint`, hoist
      parse + host validation into `connect(...transportKind:)` (before transport construction
      and `bridge.connect()`), and change `connectWithBridge` to accept the resolved
      `(host, port)` so parsing happens exactly once (`transport-servicing` delta)
- [ ] 1.3 Tests for kind dispatch: `.automatic` never yields QUIC; Linux `.quic` throws
      `ENOTSUP` (compile-checked via `#if !canImport(Network)` path); then update the `switch`
      at `Context.swift:1124` (transport construction stubbed until task 2). The
      below-availability-floor `ENOTSUP` branch is unreachable on CI hosts — verify by code
      inspection and mark the scenario manual, per the spec note

## 2. SMBQUICConfiguration + QUICTransportApple

- [ ] 2.1 Tests for `SMBQUICConfiguration` defaults (`allowsInsecureTrust == false`, empty roots,
      Sendable); then implement the struct (`quic-transport-apple` spec, D5)
- [ ] 2.2 Implement `QUICTransportApple` skeleton: availability-gated final class, NSLock-guarded
      state, chunk-FIFO + single parked `receive()` waiter, idempotent `close()` resuming the
      parked waiter with empty `Data` (graceful EOF, matching `TCPTransportApple.signalClosed()`;
      `ENOTCONN` only for never-connected) — mirror `TCPTransportApple`'s shape (D3). Unit-test
      the state-machine paths that don't need a live server (never-connected `ENOTCONN`, double
      close, receive-after-close returns empty `Data`)
- [ ] 2.3 Implement `connect(host:port:)`: `NWParameters(quic:)` with ALPN `"smb"`, SNI = host,
      TLS trust wiring from `SMBQUICConfiguration` (verify block ONLY when an override is set);
      map failures to `POSIXError`, preserve `CancellationError` (D2, D5)
- [ ] 2.4 Implement `send(_:)`/`receive()` over the single bidirectional stream with re-arming
      `NWConnection.receive`, empty-`Data` graceful EOF, `POSIXError` on abnormal loss
- [ ] 2.5 Wire `.quic` in the `Context.swift` kind dispatch to construct `QUICTransportApple`
      (replacing the task-1.3 stub); run the full seam unit suite (bridge/servicing tests must
      stay green)

## 3. SMB2Manager public API

- [ ] 3.1 Tests then implementation for `SMB2Manager.transportKind` (default `.automatic`) and
      `quicConfiguration`, consulted in `connect(shareName:encrypted:)`
      (`AMSMB2.swift:1511` area)
- [ ] 3.2 Tests then implementation for serialization: `transportKind` round-trips through
      `NSSecureCoding`/`Codable` via a private string mapping (no public `RawRepresentable`
      added to `SMBTransportKind`), old archives decode to `.automatic`, `quicConfiguration`
      never serialized; Linux connect path honors the property (`.quic` → `ENOTSUP`, no silent
      downgrade)
- [ ] 3.3 ObjC compat check: confirm the new surface is either exposed sensibly or intentionally
      Swift-only; document the decision in design.md if it changes

## 4. Interop verification (the release gate)

- [ ] 4.1 Stand up the interop rig: Samba 4.23+ with `server smb transports = +quic` in a
      Lima/UTM VM with a 6.14+ kernel and `quic.ko` (or a Windows Server 2025 target); document
      the repeatable procedure in `docs/` (quic.ko constraint makes Docker CI infeasible — see
      design Risks)
- [ ] 4.2 First-contact gate: QUIC handshake + NEGOTIATE round-trip; **verify the 4-byte framing
      assumption on the wire** (design D2 must-verify). If framing differs, stop and fix in the
      libsmb2 fork seam before proceeding
- [ ] 4.3 Interop matrix: NTLM auth, share list, directory listing, large read/write,
      cancel/timeout mid-transfer, cert-mismatch failure, IP-target rejection, QUIC-only
      failure mode (server without QUIC), graceful disconnect
- [ ] 4.4 Fold interop findings back: idle-timeout/keepalive tuning only if 4.3 shows premature
      teardown; update design.md with what was actually observed

## 5. Documentation and archive

- [ ] 5.1 Update `docs/API.md` per the `api-reference` delta (new types, availability floors,
      QUIC policy and error conditions, caller-side fallback pattern)
- [ ] 5.2 Update `docs/ARCHITECTURE.md` (QUIC conformer beside TCP in the seam diagram) and
      README (opt-in usage example with the security caveats)
- [ ] 5.3 Dead-code sweep (every new symbol has a call site outside its file), SwiftFormat,
      full `swift test --disable-sandbox` green
- [ ] 5.4 Ensure artifacts reflect what shipped, close AMSMB2 #29 / RandomPlayer #346, archive
      via `/opsx:archive`
