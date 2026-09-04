# transport-connect-ordering Specification

## Purpose
TBD - created by archiving change fix-seam-connect-ordering. Update Purpose after archive.

## Requirements

### Requirement: Transport is connected before libsmb2 starts NEGOTIATE

When a connection is established through the seam, the underlying `SMBTransport` SHALL be fully
connected (channel live, able to carry bytes) **before** libsmb2 fires the connect callback that
begins the NEGOTIATE exchange. The library SHALL NOT report a `>= 0` external-transport connect
result to libsmb2 while the transport channel is not yet established.

#### Scenario: First outbound PDU finds a live channel

- **WHEN** the seam connect path drives `smb2_connect_share_async` and libsmb2 begins NEGOTIATE
- **THEN** the bridge's first outbound `SMBTransport.send(_:)` succeeds (no `POSIXError(.ENOTCONN)`)
- **AND** the first inbound delivery from the transport reaches the bridge's store rather than
  failing with "Socket is not connected"

#### Scenario: No-fd invariant holds throughout the seam connection

- **WHEN** the external transport is installed via `smb2_set_transport(context, SMB2_TRANSPORT_AUTO, ext)`
- **THEN** `smb2_get_fd(context)` returns `-1` at connect time and for the lifetime of the seam
  connection (no native socket fd is ever owned)

### Requirement: Transport connect failure surfaces as a thrown error

A failure to establish the transport SHALL propagate as the connect call's thrown `POSIXError`.
The library SHALL NOT swallow the connect error in a detached task, SHALL NOT surface it as an
unrelated `EPERM`/`ENOTCONN`, and SHALL tear down the seam (bridge, inbound-ready handler,
installed external transport) without leaving a pending operation registered.

#### Scenario: Refused connection throws, not EPERM

- **WHEN** `SMB2Client` connects through the seam to an endpoint that refuses the TCP connection
- **THEN** the `connect(server:share:user:transportKind:)` call throws a `POSIXError` reflecting
  the connect failure (e.g. `.ECONNREFUSED`/`.ETIMEDOUT`), not `POSIXError(.init(1))` (`EPERM`)
- **AND** no operation remains in the pending-operations table and the bridge is torn down

#### Scenario: Connect error is not silently dropped

- **WHEN** the transport's `connect(host:port:)` throws during a seam connection attempt
- **THEN** the thrown error is observed by the caller (the error is not confined to a
  fire-and-forget `Task { try? await ... }`)

### Requirement: Seam connect + NTLM authentication succeeds against a live server

A full SMB2/3 connect with NTLM authentication through the seam SHALL succeed against a live
Samba server, reaching tree-connect, with no fd owned.

#### Scenario: Connect and authenticate over the seam

- **WHEN** an integration test connects with valid NTLM credentials and
  `SMB_TRANSPORT=seam` to a live Samba server
- **THEN** the connection and tree-connect complete without error
- **AND** `smb2_get_fd(context) == -1` confirms the seam (external-transport) path was used

### Requirement: Directory listing succeeds through the seam

After a seam connection, enumerating a share's contents SHALL return correct results, exercising
multiple request/response round-trips over the bridge.

#### Scenario: List a populated directory

- **WHEN** the test lists a directory containing known entries over the seam
- **THEN** the returned entries match the expected set (names/attributes), proving multi-PDU
  request/response flow over the bridge works

### Requirement: Large read and write round-trip through the seam

Reads and writes larger than a single PDU SHALL transfer byte-exact data through the seam,
exercising the pushed inbound path, the outbound pump and the no-fd servicing loop under
sustained I/O.

#### Scenario: Large write then read-back matches

- **WHEN** the test writes a multi-megabyte payload and reads it back over the seam
- **THEN** the read-back bytes equal the written bytes exactly
- **AND** no `ENOTCONN`/`ECONNRESET` occurs during the transfer

### Requirement: Cancellation and timeout are honored through the seam

Cancelling an in-flight seam operation SHALL throw `CancellationError` and tear down cleanly; a
seam operation that exceeds the configured timeout SHALL throw `POSIXError(.ETIMEDOUT)`. Neither
SHALL leak pump tasks, continuations, or pending operations.

#### Scenario: Cancel mid-operation

- **WHEN** a seam operation's owning task is cancelled before completion
- **THEN** the call throws `CancellationError`, the seam is torn down, and no continuation remains
  suspended

#### Scenario: Operation timeout fires

- **WHEN** a seam operation does not complete within the configured timeout
- **THEN** the call throws `POSIXError(.ETIMEDOUT)` and the pending operation is removed

### Requirement: Seam integration suite is the regression gate

The seam acceptance suite (`SMB2SeamIntegrationTests`) SHALL pass against a live Samba server with
`SMB_TRANSPORT=seam`, and SHALL be the gate that proves the connect-ordering defect is fixed.

#### Scenario: Full seam suite passes against live Samba

- **WHEN** `SMB2SeamIntegrationTests` runs against a live Samba server over the seam
- **THEN** all scenarios (connect/NTLM, list, large read/write, cancel/timeout) pass with zero
  failures
- **AND** every connection asserts `smb2_get_fd == -1`
