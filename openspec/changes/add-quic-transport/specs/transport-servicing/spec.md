# transport-servicing Delta Specification

## MODIFIED Requirements

### Requirement: Opt-in transport selection at connect

`SMB2Client` connect SHALL accept an optional `SMBTransportKind`. When none is supplied, the
legacy libsmb2-owned TCP path runs unchanged. When a seam kind is supplied (Apple only), the
client SHALL construct the transport for that kind — `TCPTransportApple` for `.tcp`/`.automatic`,
`QUICTransportApple` for `.quic` on supported OS versions (throwing `POSIXError(.ENOTSUP)` on
older OS versions) — wrap it in the bridge, and call `smb2_set_transport` before
`smb2_connect_share_async`. Seam endpoint parsing SHALL be transport-aware: the default port
when the server string carries no explicit port is 445 for TCP kinds and 443 for `.quic`.

#### Scenario: Default selection uses the legacy path

- **WHEN** a connection is opened without specifying a transport kind
- **THEN** `smb2_set_transport` is not called
- **AND** the `DispatchSource`/`SocketMonitor` fd path drives servicing exactly as before

#### Scenario: Seam selection installs the external transport before connect

- **WHEN** a seam transport kind is selected on Apple
- **THEN** `smb2_set_transport(ctx, ext-selector, ext)` is called before `smb2_connect_share_async`
- **AND** the bridge's `ext` struct is supplied

#### Scenario: Kind dispatch constructs the matching transport

- **WHEN** `.quic` is supplied on a supported OS version
- **THEN** a `QUICTransportApple` instance backs the bridge
- **AND** the same servicing loop, timer hooks, and cancellation semantics apply unchanged

#### Scenario: Per-kind default port

- **WHEN** the server string has no explicit port
- **THEN** endpoint parsing yields port 445 for `.tcp`/`.automatic` and 443 for `.quic`
- **AND** an explicit port in the server string is honored for any kind
