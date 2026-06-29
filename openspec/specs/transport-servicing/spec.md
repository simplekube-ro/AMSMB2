# transport-servicing Specification

## Purpose
Define how `SMB2Client` drives libsmb2 when a seam transport is active, without a socket file descriptor. Connect SHALL accept an optional `SMBTransportKind`; the legacy libsmb2-owned TCP path runs unchanged when none is supplied. When a seam kind is selected (Apple only), the client SHALL install the external transport before connecting using the `SMB2_TRANSPORT_QUIC`/`SMB2_TRANSPORT_AUTO` selector (never `SMB2_TRANSPORT_TCP`, the naming trap), drive a no-fd servicing loop from inbound-ready signals on `eventLoopQueue`, and add timer-driven servicing via `smb2_get_timeout`/`smb2_service_timeout`. Existing continuation, cancellation, and timeout semantics SHALL be preserved unchanged.

## Requirements

### Requirement: Opt-in transport selection at connect

`SMB2Client` connect SHALL accept an optional `SMBTransportKind`. When none is supplied, the
legacy libsmb2-owned TCP path runs unchanged. When a seam kind is supplied (Apple only), the
client SHALL construct the transport, wrap it in the bridge, and call `smb2_set_transport` before
`smb2_connect_share_async`.

#### Scenario: Default selection uses the legacy path

- **WHEN** a connection is opened without specifying a transport kind
- **THEN** `smb2_set_transport` is not called
- **AND** the `DispatchSource`/`SocketMonitor` fd path drives servicing exactly as before

#### Scenario: Seam selection installs the external transport before connect

- **WHEN** a seam transport kind is selected on Apple
- **THEN** `smb2_set_transport(ctx, ext-selector, ext)` is called before `smb2_connect_share_async`
- **AND** the bridge's `ext` struct is supplied

### Requirement: External selector is QUIC/AUTO, never TCP (naming trap)

To route the external NIO transport through the seam, the client SHALL pass `SMB2_TRANSPORT_QUIC`
or `SMB2_TRANSPORT_AUTO` (with `ext` populated) to `smb2_set_transport`. It SHALL NOT pass
`SMB2_TRANSPORT_TCP`, which selects libsmb2's built-in socket and ignores `ext`.

#### Scenario: Seam uses the external selector

- **WHEN** the seam is selected
- **THEN** the transport-type argument to `smb2_set_transport` is the external selector
  (`SMB2_TRANSPORT_AUTO` or `SMB2_TRANSPORT_QUIC`), not `SMB2_TRANSPORT_TCP`

#### Scenario: No fd under the seam

- **WHEN** a seam transport is active
- **THEN** `smb2_get_fd(context)` returns `-1` (no built-in socket fd to monitor)

### Requirement: No-fd servicing loop driven by inbound-ready signals

When a seam transport is active, the client SHALL drive libsmb2 without an fd: inbound bytes (or
EOF/error) appended by the bridge SHALL signal the event loop to call `smb2_service` on
`eventLoopQueue` with `revents` derived from `smb2_which_events`. Outgoing PDUs SHALL be flushed by
calling `smb2_service` with `POLLOUT` after an operation is queued when `smb2_which_events`
indicates pending output. All libsmb2 calls SHALL remain on `eventLoopQueue`.

#### Scenario: Inbound bytes trigger servicing

- **WHEN** the bridge appends inbound bytes from the transport
- **THEN** `smb2_service` is called on the event loop queue
- **AND** the corresponding operation's `CheckedContinuation` resumes (no hang)

#### Scenario: Outgoing PDU is flushed

- **WHEN** an operation is queued and `smb2_which_events` indicates `POLLOUT`
- **THEN** `smb2_service` is called with `POLLOUT`, pushing bytes into the bridge's outbound FIFO

#### Scenario: Connect completes without an fd poll

- **WHEN** a seam connection is established
- **THEN** the connect completes via bridge-driven servicing (not via `poll(fd)`)
- **AND** the connect continuation resumes on success

### Requirement: Timer-driven servicing via smb2_get_timeout / smb2_service_timeout

When a seam transport is active, the client SHALL query `smb2_get_timeout` after service passes and
schedule an `eventLoopQueue.asyncAfter` that calls `smb2_service_timeout` at the deadline, then
reschedule. Timers SHALL be cancelled on teardown.

#### Scenario: Timeout path fires when no reply arrives

> **Partially deferred to T8 (#27) — see tasks.md 6.5.** The timer *wiring* is verified at the
> unit level (`testTimerDrivenTimeoutFiresWithoutHang`: `smb2_set_timeout` is called and the
> `eventLoopQueue.asyncAfter` chain runs `smb2_service_timeout` without hanging). The end-to-end
> behavior below — `smb2_service_timeout` aborting a real in-flight PDU and resuming the
> continuation with a timeout error — is NOT unit-testable here because `MockTransport` cannot emit
> valid SMB2 without crashing libsmb2's parser (premise-falsified) and a faithful exercise requires
> a live server. It is deferred to the T8 Samba integration suite.

- **WHEN** a request is in-flight against a mock transport that never replies and the timeout
  elapses
- **THEN** `smb2_service_timeout` is invoked
- **AND** the operation's continuation resumes with a timeout error (no permanent hang)

### Requirement: Existing continuation, cancellation, and timeout semantics preserved

The seam servicing loop SHALL reuse the existing `CheckedContinuation`, `CBData` `isAbandoned`
guard, per-operation `asyncAfter` timeout, and `withTaskCancellationHandler` mechanisms unchanged.

#### Scenario: Full mock exchange services correctly

> **Deferred to T8 (#27) — see tasks.md 6.1.** This scenario is NOT satisfied at the unit-test
> level: `MockTransport` cannot speak real SMB2 without triggering a SIGSEGV in libsmb2's PDU
> parser (the premise of a "full request/response over a mock" is falsified by libsmb2 reality).
> A faithful full-exchange verification therefore requires a live Samba server and is deferred to
> the T8 integration suite. The unit-level `SMB2ServicingLoopTests` instead cover the executable
> proxies (no-hang connect, inbound-ready signalling, AUTO selector + `fd == -1`, timer wiring,
> cancellation teardown).

- **WHEN** a full request/response is driven through the seam servicing loop using `MockTransport`
  and the bridge
- **THEN** the continuation resumes with the correct result and there is no hang

#### Scenario: Legacy path is byte-for-byte unchanged

- **WHEN** the seam is not selected
- **THEN** behavior matches the legacy `DispatchSource` path and existing unit tests stay green

#### Scenario: Cancellation tears down the seam servicing cleanly

- **WHEN** a task is cancelled during a seam operation
- **THEN** the operation throws `CancellationError`, timers and pumps are torn down, and nothing
  leaks

#### Scenario: No Swift 6 concurrency warnings

- **WHEN** the servicing loop is compiled with `-strict-concurrency=complete`
- **THEN** there are zero new concurrency warnings
