## MODIFIED Requirements

### Requirement: SMBTransport protocol abstracts the wire layer

The library SHALL define a public `SMBTransport` protocol with async
`connect(host:port:onReceive:)`, `send(_:)`, and `close()` operations that carry SMB2 bytes over
the network. The protocol SHALL NOT depend on SwiftNIO or libsmb2, so it can be implemented and
unit-tested in isolation and reused by both the TCP and QUIC transports.

The inbound direction SHALL be push: `connect` takes an `onReceive` handler of the public type
`InboundReceiver` (`@Sendable (Result<Data, POSIXError>) -> Void`, declared alongside the
protocol so conformers on every platform share one spelling), and the transport
invokes it on its own serial delivery queue with `Result<Data, POSIXError>` — once per inbound
chunk in arrival order, once with empty `Data` for graceful EOF, or once with a `POSIXError` for
abnormal connection loss. EOF and error are terminal: nothing is delivered after either, and
nothing is delivered once `close()` has begun. A `connect` that throws SHALL never invoke its
handler, and a `connect` that is rejected because the instance already has an attempt or a
connection SHALL NOT replace the live handler. The handler is expected to return promptly and
never suspend. There SHALL be no pull operation (`receive()`) and no separate handler
registration step: a connection cannot exist without its receiver.

#### Scenario: Protocol is NIO-free and libsmb2-free

- **WHEN** the module defining `SMBTransport` is compiled
- **THEN** it imports neither SwiftNIO nor the `SMB2` C module
- **AND** the protocol is `public`

#### Scenario: Seam buffer type is Data

- **WHEN** the `send(_:)` signature and the `onReceive` handler's payload are inspected
- **THEN** the byte payload type is `Data` (not `ByteBuffer`)

#### Scenario: Connection cannot exist without a receiver

- **WHEN** a conformer is connected through the protocol
- **THEN** the caller supplied the `onReceive` handler in the same `connect` call — there is no
  way to open a connection with no receiver and no registration step that could be skipped or
  ordered after connect
- **NOTE** a structural property verified by the compiler (the protocol has no other connect
  signature and no handler setter) and by inspection; no runtime test can fail it

#### Scenario: Inbound delivery contract

- **WHEN** a connected transport receives chunks, then reaches EOF or fails
- **THEN** the handler observes every chunk in arrival order, then exactly one terminal delivery
  (empty `Data` or an error), and nothing afterwards — and nothing at all once `close()` has begun

#### Scenario: Failed connect never delivers

- **WHEN** `connect(host:port:onReceive:)` throws
- **THEN** the handler passed to that call is never invoked

## REMOVED Requirements

### Requirement: MockTransport in-memory loopback double

**Reason**: The seam no longer has a `receive()` for a send-loopback to feed; a mock that echoed
sent bytes back as inbound data would also feed libsmb2's own PDUs back to it, which the previous
`sendsAreDropped` flag existed to suppress.

**Migration**: Replaced by "MockTransport in-memory push double" below. Tests that read
`receive()` to observe sent bytes read the mock's sent log instead; tests that used the loopback
to produce inbound data inject it through the mock's delivery helpers.

## ADDED Requirements

### Requirement: MockTransport in-memory push double

The test target SHALL provide a `MockTransport` conforming to `SMBTransport` with no real socket
and no libsmb2 dependency, for use by bridge and servicing tests. It SHALL let a test inject
inbound chunks, graceful EOF, and an error, each delivered to the `onReceive` handler supplied at
connect (terminal-once; nothing after `close()`; the error is a `POSIXError`), and SHALL record every `send(_:)` payload in
order so a test can observe outbound delivery. It SHALL support injecting connection failure and
never-replying (simply not injecting anything).

#### Scenario: Mock delivers injected inbound bytes

- **WHEN** a test connects the mock with a handler and injects two chunks
- **THEN** the handler receives the same two chunks, in order, with no server and no libsmb2
  involvement

#### Scenario: Mock records sent bytes

- **WHEN** bytes are passed to `MockTransport.send(_:)`
- **THEN** the test can read them back from the mock's sent log in send order, and they are not
  delivered to the inbound handler

#### Scenario: Mock signals graceful EOF

- **WHEN** the mock is told to close gracefully
- **THEN** the handler receives empty `Data` exactly once and nothing afterwards

#### Scenario: Mock surfaces connection failure

- **WHEN** the mock is configured to fail connecting
- **THEN** `connect(host:port:onReceive:)` throws a `POSIXError` and the handler is never invoked
