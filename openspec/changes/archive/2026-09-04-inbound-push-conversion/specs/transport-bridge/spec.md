## MODIFIED Requirements

### Requirement: Inbound buffering shim with would-block and EOF semantics

The bridge SHALL supply its inbound handler to the transport when it connects it. Each delivery
the transport makes (a chunk, EOF, or an error) SHALL be recorded in the bridge's inbound store
synchronously on the transport's delivery thread — no inbound task and no executor hop between
the transport and the store — and SHALL then fire the inbound-ready signal. C
`recv(userdata, buf, max_len)` SHALL drain synchronously from that store with these semantics:
bytes available → copy up to `max_len` and return the count; empty but open → return the
libsmb2 would-block signal; empty and EOF → return `0`; errored/closed → return a negative
error. A failure of the outbound pump's `send` SHALL be recorded in the store as an error
through the same path. The bridge SHALL NOT add a terminal-once guard of its own (EOF and error
are recorded whenever they arrive; only the closed state suppresses them), so `recv`'s precedence
is unchanged. Deliveries that arrive before the inbound-ready handler has been registered SHALL
be stored, and registering the handler SHALL fire the inbound-ready signal exactly once if the
store already holds bytes, EOF or an error at that moment (otherwise the first delivery after
registration signals as usual) — a pre-registration delivery is never a lost wakeup. Deliveries
that arrive after the bridge has closed SHALL be ignored (no append, no signal).

#### Scenario: recv returns buffered bytes

- **WHEN** the transport has delivered bytes and C `recv` is called
- **THEN** up to `max_len` bytes are copied into the C buffer and that count is returned

#### Scenario: recv would-block when empty and open

- **WHEN** C `recv` is called while the inbound store is empty and the transport is still open
- **THEN** it returns the would-block signal (does not block, does not return 0)

#### Scenario: recv returns EOF on graceful close

- **WHEN** the transport has delivered graceful EOF (empty `Data`) and the inbound store is drained
- **THEN** C `recv` returns `0`

#### Scenario: Delivery is appended on the delivery thread with no task in between

- **WHEN** the transport invokes the bridge's handler with a chunk
- **THEN** the chunk is in the inbound store and the inbound-ready signal has fired before the
  handler returns, and the bridge exposes no inbound pump to start

#### Scenario: Delivery before the ready handler is registered is not lost

- **WHEN** the transport delivers a chunk (or EOF, or an error) after connect but before the
  inbound-ready handler is registered, and the handler is registered afterwards
- **THEN** the inbound-ready signal fires exactly once during registration, and C `recv` returns
  that chunk's bytes (or `0`, or the error) on the next drain

#### Scenario: Registration with an empty store does not signal

- **WHEN** the inbound-ready handler is registered while the store is empty and open
- **THEN** no signal fires until the first delivery

#### Scenario: Delivery after close is ignored

- **WHEN** the bridge has been closed and the transport delivers a chunk, EOF, or error
- **THEN** nothing is appended, no inbound-ready signal fires, and C `recv` keeps reporting the
  closed error

### Requirement: Clean teardown on close and cancel

The `close` callback, `SMB2Client` teardown, and task cancellation SHALL each cancel the outbound
pump task, call `SMBTransport.close()`, mark the store closed, clear the inbound-ready handler,
and resume any suspended outbound continuation, with no leaked tasks or continuations. The
inbound handler the bridge gives the transport SHALL NOT retain the bridge, so the bridge's
lifetime remains exactly the `userdata` retain balanced in the close trampoline.

#### Scenario: Round-trip through C callbacks via MockTransport

- **WHEN** a unit test pushes bytes through the C `send` callback and injects inbound bytes
  through a `MockTransport`, then drains them through the C `recv` callback
- **THEN** the bytes round-trip correctly, including would-block-when-empty and EOF-on-close
- **AND** there is no real socket and no server

#### Scenario: Cancellation tears down cleanly

- **WHEN** the owning task is cancelled mid-operation
- **THEN** the outbound pump task stops, the transport is closed, and no continuation is left
  suspended

#### Scenario: Handler does not retain the bridge

- **WHEN** a bridge has connected a transport (which holds the bridge's inbound handler) and the
  bridge's last strong reference is released
- **THEN** the bridge is deallocated while the transport still exists

#### Scenario: No Swift 6 concurrency warnings

- **WHEN** the bridge is compiled with `-strict-concurrency=complete`
- **THEN** there are zero new concurrency warnings
