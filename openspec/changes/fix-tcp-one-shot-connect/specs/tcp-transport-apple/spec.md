# tcp-transport-apple Specification (delta)

## MODIFIED Requirements

### Requirement: Connect, send, receive, close over a NIO channel

`connect(host:port:)` SHALL establish a TCP connection via a Network.framework-backed NIO channel
and support cancellation. `send(_:)` SHALL write bytes to the channel. `receive()` SHALL deliver
inbound bytes, buffering them via a channel handler so the bridge's synchronous `recv` can drain
incrementally. `close()` SHALL tear the channel down cleanly.

`connect(host:port:)` SHALL additionally be strictly **one-shot** per instance: the first
call atomically reserves the instance's single connect attempt under the state lock, before
any bootstrap or channel exists, and every other call SHALL fail promptly and
deterministically without creating a bootstrap, a channel, or any network activity, and
without touching the owning attempt's channel or state. The rejection error mapping SHALL
be: attempt in flight → `POSIXError(.EALREADY)`; after successful connect →
`POSIXError(.EISCONN)`; after a failed attempt → `POSIXError(.EALREADY)` (retry after a
failed first attempt is NOT supported — one instance maps to one connection lifetime;
callers construct a fresh transport, as `SMB2Client` does); after `close()` →
`POSIXError(.ENOTCONN)` (the conformer's existing closed-transport contract, checked before
the attempt state).

#### Scenario: Second connect while an attempt is in flight is rejected

- **WHEN** `connect` is called while another `connect` call's attempt is still in flight
- **THEN** the second call fails promptly with `POSIXError(.EALREADY)`, starts no bootstrap,
  and the owning attempt proceeds to its own outcome unaffected

#### Scenario: Connect after an established connection is rejected

- **WHEN** `connect` is called after a previous call connected successfully
- **THEN** it fails promptly with `POSIXError(.EISCONN)` and the established channel remains
  installed and usable for `send`/`receive`

#### Scenario: Retry after a failed attempt is rejected

- **WHEN** the first connect attempt has failed and `connect` is called again
- **THEN** the call fails promptly with `POSIXError(.EALREADY)` — bounded well under the
  connect timeout, proving no second network attempt ran

#### Scenario: Connect after close keeps the existing closed contract

- **WHEN** `connect` is called after `close()`
- **THEN** it throws `POSIXError(.ENOTCONN)` (the pre-existing closed-transport error),
  regardless of whether an attempt had run before the close
