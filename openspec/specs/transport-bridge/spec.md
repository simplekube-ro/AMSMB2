# transport-bridge Specification

## Purpose
Bridge libsmb2's external-transport C callbacks (`connect`, `send`, `recv`, `close`) to an async Swift `SMBTransport`. The bridge SHALL recover its Swift context from the C `userdata` pointer via `Unmanaged`, copy bytes synchronously at the C/Swift boundary (libsmb2 may free or reuse buffers immediately), and provide outbound and inbound buffering shims with would-block and EOF semantics. It SHALL tear down both pump tasks, close the transport, and resume any suspended continuations cleanly on close and cancel, with no leaks or use-after-free.

## Requirements

### Requirement: Bridge wires libsmb2 external-transport callbacks to an async SMBTransport

The library SHALL provide a bridge that populates a `smb2_external_transport` whose four C
callbacks (`connect`, `send`, `recv`, `close`) are driven by a Swift `SMBTransport`. The bridge
instance SHALL back the `userdata` pointer; the C trampolines SHALL recover it via `Unmanaged`
(C function pointers cannot capture Swift context).

#### Scenario: ext struct is populated with trampolines

- **WHEN** the bridge produces its `smb2_external_transport`
- **THEN** all four function-pointer fields are non-null
- **AND** `userdata` is the `Unmanaged` opaque pointer to the bridge

#### Scenario: Bridge outlives the libsmb2 context without leaking

- **WHEN** the bridge is retained via `passRetained` for `userdata` and later torn down
- **THEN** the single retained reference is balanced exactly once on teardown (no leak, no
  use-after-free)

### Requirement: Copy at the C/Swift boundary

The `send` callback SHALL copy bytes out of libsmb2's C `buf` synchronously inside the callback
(before returning) and operate on the owned copy for any async work, because libsmb2 may free or
reuse `buf` immediately after the callback returns. The unsafe byte-copy closure SHALL NOT contain
`await`. Likewise `recv` SHALL copy into the C `buf` synchronously from the inbound store.

#### Scenario: Sent bytes survive immediate buffer reuse

- **WHEN** the C `send` callback is invoked and the caller overwrites the source buffer
  immediately after `send` returns
- **THEN** the bytes delivered to the `SMBTransport` match the original contents (copy-at-boundary
  verified)

#### Scenario: No await inside the unsafe copy

- **WHEN** the bridge copies between C buffers and Swift `Data`
- **THEN** the copy happens in a synchronous closure with no suspension point inside it

### Requirement: Outbound buffering shim drains to the transport

C `send(userdata, buf, len)` SHALL enqueue the copied bytes and return `len` immediately; an async
outbound pump task SHALL drain the queue into `SMBTransport.send(_:)`.

#### Scenario: send returns immediately and is delivered asynchronously

- **WHEN** the C `send` callback enqueues bytes
- **THEN** it returns the byte count without blocking on the network
- **AND** the outbound pump subsequently delivers those bytes to the transport in order

### Requirement: Inbound buffering shim with would-block and EOF semantics

An async inbound pump task SHALL call `SMBTransport.receive()` and append results to an inbound
store. C `recv(userdata, buf, max_len)` SHALL drain synchronously from that store with these
semantics: bytes available → copy up to `max_len` and return the count; empty but open → return
the libsmb2 would-block signal; empty and EOF → return `0`; errored/closed → return a negative
error.

#### Scenario: recv returns buffered bytes

- **WHEN** the inbound pump has appended bytes and C `recv` is called
- **THEN** up to `max_len` bytes are copied into the C buffer and that count is returned

#### Scenario: recv would-block when empty and open

- **WHEN** C `recv` is called while the inbound store is empty and the transport is still open
- **THEN** it returns the would-block signal (does not block, does not return 0)

#### Scenario: recv returns EOF on graceful close

- **WHEN** the transport has reported graceful EOF (empty `Data`) and the inbound store is drained
- **THEN** C `recv` returns `0`

### Requirement: Clean teardown on close and cancel

The `close` callback, `SMB2Client` teardown, and task cancellation SHALL each cancel both pump
tasks, call `SMBTransport.close()`, mark the store closed, and resume any suspended pump
continuations, with no leaked tasks or continuations.

#### Scenario: Round-trip through C callbacks via MockTransport

- **WHEN** a unit test pushes bytes through the C `send` and `recv` callbacks against a
  `MockTransport`
- **THEN** the bytes round-trip correctly, including would-block-when-empty and EOF-on-close
- **AND** there is no real socket and no server

#### Scenario: Cancellation tears down cleanly

- **WHEN** the owning task is cancelled mid-operation
- **THEN** both pump tasks stop, the transport is closed, and no continuation is left suspended

#### Scenario: No Swift 6 concurrency warnings

- **WHEN** the bridge is compiled with `-strict-concurrency=complete`
- **THEN** there are zero new concurrency warnings
