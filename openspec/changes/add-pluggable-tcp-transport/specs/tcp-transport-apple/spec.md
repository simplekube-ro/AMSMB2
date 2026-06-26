## ADDED Requirements

### Requirement: TCPTransportApple implements SMBTransport over NIOTransportServices

The library SHALL provide `TCPTransportApple`, a concrete `SMBTransport` backed by
`NIOTransportServices` (SwiftNIO over Network.framework), carrying SMB2 bytes over TCP. It SHALL
be guarded with `#if canImport(Network)` and SHALL NOT exist on Linux. It SHALL convert between the
seam's `Data` payloads and NIO `ByteBuffer` internally.

#### Scenario: Conforms and builds on Apple

- **WHEN** the package builds on an Apple platform
- **THEN** `TCPTransportApple` conforms to `SMBTransport` and compiles

#### Scenario: Absent on Linux without breaking the build

- **WHEN** the package builds for Linux
- **THEN** `TCPTransportApple` is not compiled and the Linux build still succeeds

### Requirement: Connect, send, receive, close over a NIO channel

`connect(host:port:)` SHALL establish a TCP connection via a Network.framework-backed NIO channel
and support cancellation. `send(_:)` SHALL write bytes to the channel. `receive()` SHALL deliver
inbound bytes, buffering them via a channel handler so the bridge's synchronous `recv` can drain
incrementally. `close()` SHALL tear the channel down cleanly.

#### Scenario: Inbound bytes are buffered for incremental drain

- **WHEN** the channel receives more bytes than a single bridge `recv` consumes
- **THEN** the surplus is retained and delivered on subsequent `receive()` calls (no loss)

#### Scenario: Graceful close yields EOF

- **WHEN** the channel reaches end-of-stream
- **THEN** `receive()` reports graceful EOF (empty `Data`) to the bridge

### Requirement: Errors follow the POSIXError convention

Connect failure and cancellation SHALL surface as `POSIXError(.CODE)` values (no custom Error
types), consistent with the rest of the library.

#### Scenario: Connect failure throws POSIXError

- **WHEN** a connection attempt fails
- **THEN** `connect(host:port:)` throws a `POSIXError`

#### Scenario: Cancellation during connect throws

- **WHEN** the connecting task is cancelled before the connection completes
- **THEN** `connect(host:port:)` throws (cancellation/`POSIXError`) and leaks no channel

#### Scenario: No Swift 6 concurrency warnings

- **WHEN** `TCPTransportApple` is compiled with `-strict-concurrency=complete`
- **THEN** there are zero new concurrency warnings
