## ADDED Requirements

### Requirement: SMBTransport protocol abstracts the wire layer

The library SHALL define a public `SMBTransport` protocol with async `connect(host:port:)`,
`send(_:)`, `receive()`, and `close()` operations that carry SMB2 bytes over the network. The
protocol SHALL NOT depend on SwiftNIO or libsmb2, so it can be implemented and unit-tested in
isolation and reused by both TCP and a future QUIC transport.

#### Scenario: Protocol is NIO-free and libsmb2-free

- **WHEN** the module defining `SMBTransport` is compiled
- **THEN** it imports neither SwiftNIO nor the `SMB2` C module
- **AND** the protocol is `public`

#### Scenario: Seam buffer type is Data

- **WHEN** `send(_:)` and `receive()` signatures are inspected
- **THEN** the byte payload type is `Data` (not `ByteBuffer`)

### Requirement: SMBTransportKind enumerates selectable transports

The library SHALL define a public `SMBTransportKind` enum with `tcp`, `quic`, and `automatic`
cases, used to select which transport a connection uses.

#### Scenario: Kind cases exist and are Sendable

- **WHEN** `SMBTransportKind` is referenced from Swift
- **THEN** the cases `.tcp`, `.quic`, and `.automatic` are available
- **AND** the type conforms to `Sendable`

### Requirement: Seam satisfies Swift 6 strict concurrency

`SMBTransport` SHALL be `Sendable`, and all seam types SHALL compile under
`-strict-concurrency=complete` with zero new warnings.

#### Scenario: No concurrency warnings

- **WHEN** the seam types are compiled with complete strict-concurrency checking
- **THEN** there are zero new Sendable or actor-isolation warnings

### Requirement: MockTransport in-memory loopback double

The test target SHALL provide a `MockTransport` conforming to `SMBTransport` that round-trips
bytes in memory with no real socket and no libsmb2 dependency, for use by bridge and servicing
tests. It SHALL support injecting connection failure, never-replying (for timeout tests), and
graceful EOF.

#### Scenario: Mock round-trips bytes

- **WHEN** a test sends bytes through `MockTransport.send(_:)` and reads them via `receive()`
- **THEN** the same bytes are returned, with no server and no libsmb2 involvement

#### Scenario: Mock signals graceful EOF

- **WHEN** the mock is told to close gracefully
- **THEN** a subsequent `receive()` yields empty `Data` (EOF)

#### Scenario: Mock surfaces connection failure

- **WHEN** the mock is configured to fail connecting
- **THEN** `connect(host:port:)` throws a `POSIXError`
