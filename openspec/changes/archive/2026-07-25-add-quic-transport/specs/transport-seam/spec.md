# transport-seam Delta Specification

## MODIFIED Requirements

### Requirement: SMBTransport protocol abstracts the wire layer

The library SHALL define a public `SMBTransport` protocol with async `connect(host:port:)`,
`send(_:)`, `receive()`, and `close()` operations that carry SMB2 bytes over the network. The
protocol SHALL NOT depend on SwiftNIO or libsmb2, so it can be implemented and unit-tested in
isolation and reused by both the TCP and QUIC transports.

#### Scenario: Protocol is NIO-free and libsmb2-free

- **WHEN** the module defining `SMBTransport` is compiled
- **THEN** it imports neither SwiftNIO nor the `SMB2` C module
- **AND** the protocol is `public`

#### Scenario: Seam buffer type is Data

- **WHEN** `send(_:)` and `receive()` signatures are inspected
- **THEN** the byte payload type is `Data` (not `ByteBuffer`)

### Requirement: SMBTransportKind enumerates selectable transports

The library SHALL define a public `SMBTransportKind` enum with `tcp`, `quic`, and `automatic`
cases, used to select which transport a connection uses. The `.quic` case SHALL select the
implemented SMB-over-QUIC transport (`QUICTransportApple`) on supported OS versions; it is no
longer a reserved placeholder.

#### Scenario: Kind cases exist and are Sendable

- **WHEN** `SMBTransportKind` is referenced from Swift
- **THEN** the cases `.tcp`, `.quic`, and `.automatic` are available
- **AND** the type conforms to `Sendable`

#### Scenario: quic is an implemented kind

- **WHEN** `.quic` is used to open a connection on a supported OS version
- **THEN** the connection is carried by `QUICTransportApple` (not rejected with `ENOTSUP`)
