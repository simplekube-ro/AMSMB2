## MODIFIED Requirements

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

### Requirement: Large read and write round-trip through the seam

Reads and writes larger than a single PDU SHALL transfer byte-exact data through the seam,
exercising the pushed inbound path, the outbound pump and the no-fd servicing loop under
sustained I/O.

#### Scenario: Large write then read-back matches

- **WHEN** the test writes a multi-megabyte payload and reads it back over the seam
- **THEN** the read-back bytes equal the written bytes exactly
- **AND** no `ENOTCONN`/`ECONNRESET` occurs during the transfer
