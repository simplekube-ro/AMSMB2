# transport-servicing Delta Specification

## MODIFIED Requirements

### Requirement: Opt-in transport selection at connect

On platforms where `Network` is importable (Apple), `SMB2Client` connect SHALL accept the
transport kind and, for QUIC, the immutable `SMBQUICConfiguration?` snapshot
(`connect(server:share:user:transportKind:quicConfiguration:)`). This configuration-aware
signature SHALL exist only under `#if canImport(Network)` — it is NOT a universal route: on
platforms without `Network` (Linux) it does not compile, and routing happens in `SMB2Manager`
on the same snapshot (`.quic` → `ENOTSUP` before any network activity; `.tcp`/`.automatic` →
the legacy libsmb2-owned socket path unchanged; see `quic-connection-policy` and design D6).
On Apple, when no kind is supplied the legacy libsmb2-owned TCP path runs unchanged; when a
seam kind is supplied, the
client SHALL parse the endpoint exactly once (`parseSeamEndpoint(server, defaultPort:)` — 445
for TCP kinds, 443 for `.quic`), run `.quic` host validation and connect-timeout
validation/normalization (design D10), and only then construct the
transport for that kind — `TCPTransportApple` for `.tcp`/`.automatic`,
`QUICTransportApple(configuration:connectTimeout:)` (receiving the validated, normalized
connect timeout) for `.quic` on supported OS versions
(throwing `POSIXError(.ENOTSUP)` on older OS versions) — wrap it in the bridge, and pass the
resolved `(host, port)` plus the kind's selector into `connectWithBridge`, which calls
`smb2_set_transport` before `smb2_connect_share_async`. The installed selector SHALL be exact,
not implementation-defined: `SMB2_TRANSPORT_AUTO` for `.tcp`/`.automatic` (unchanged shipped
behavior) and `SMB2_TRANSPORT_QUIC` for `.quic`, both with the bridge's `ext` struct
(design D9).

#### Scenario: Non-Network platforms never reach the seam connect

- **WHEN** the library is compiled on a platform without `Network` (Linux)
- **THEN** the configuration-aware `SMB2Client.connect(...transportKind:quicConfiguration:)`
  signature and the QUIC transport machinery are not part of the build, and transport-kind
  routing is handled entirely by `SMB2Manager` per `quic-connection-policy`

#### Scenario: Selector per kind is exact

- **WHEN** a seam connect installs the external transport
- **THEN** `.tcp`/`.automatic` install `SMB2_TRANSPORT_AUTO` and `.quic` installs
  `SMB2_TRANSPORT_QUIC` — never `SMB2_TRANSPORT_TCP` (which would ignore `ext`), and never left
  to an unspecified choice

#### Scenario: Default selection uses the legacy path

- **WHEN** a connection is opened without specifying a transport kind
- **THEN** `smb2_set_transport` is not called
- **AND** the `DispatchSource`/`SocketMonitor` fd path drives servicing exactly as before

#### Scenario: Seam selection installs the external transport before connect

- **WHEN** a seam transport kind is selected on Apple
- **THEN** `smb2_set_transport(ctx, ext-selector, ext)` is called before `smb2_connect_share_async`
- **AND** the bridge's `ext` struct is supplied

#### Scenario: Kind dispatch constructs the matching transport

- **WHEN** `.quic` is supplied on a supported OS version
- **THEN** a `QUICTransportApple` instance backs the bridge
- **AND** the same servicing loop, timer hooks, and cancellation semantics apply unchanged

#### Scenario: Per-kind default port

- **WHEN** the server string has no explicit port
- **THEN** endpoint parsing yields port 445 for `.tcp`/`.automatic` and 443 for `.quic`
- **AND** an explicit port in the server string is honored for any kind

## ADDED Requirements

### Requirement: Seam-connect bridge ownership is cancellation-safe from eager connect to installation

`connectWithBridge` SHALL cover the entire interval from before the eager `bridge.connect`
until ownership is transferred into `transportBridge` with a single cancellation scope and a
lock-protected bridge-ownership handoff (design D12) in which exactly one owner is responsible
for closing the bridge at every point. When `bridge.connect` returns or throws, the connect
path SHALL perform one lock-protected **eager-completion reconciliation** transition that
atomically combines the handoff state, the connect result, and whether cancellation previously
won, and assigns the single cleanup/error duty:

- success while `eagerConnecting` → transition to `localOwned`, no close, proceed toward
  installation;
- success while `cancelled` → consume the cancelled state (terminal `finished`), call
  `bridge.close()` exactly once, throw `CancellationError`, schedule no installation and call
  no libsmb2 API;
- a cancellation-shaped failure (`CancellationError` or `POSIXError(.ECANCELED)`) while
  `cancelled` → consume the cancelled state, call `bridge.close()` exactly once (the
  bridge-level ownership release — required even if the transport already cancelled its
  underlying channel/connection, whose own close is idempotent), and **normalize** the
  caller-visible error to `CancellationError` — never a raw `ECANCELED` on a cancellation
  win; no installation, no libsmb2 call;
- any failure while still `eagerConnecting` → transition to `finished`, call `bridge.close()`
  exactly once, and rethrow the mapped original transport error (not `CancellationError`); no
  installation, no libsmb2 call.

The transport's *internal* cancellation error SHALL NOT be assumed to be `CancellationError`:
`TCPTransportApple.connect` maps task cancellation to `POSIXError(.ECANCELED)`; normalization
to `CancellationError` is the reconciliation's duty. A cancellation racing an ordinary eager
failure SHALL be decided by the same single lock-protected reconciliation — cancellation is
caller-visible iff its transition to `cancelled` committed before the reconciliation claim,
the transport failure otherwise — and exactly one path performs `bridge.close()` either way.

The remaining owners are: the cancellation handler while the connected bridge is locally
owned; the install block for its own failure paths (reachable only after its successful
install claim); and `teardownSeam()` once `transportBridge` is assigned. Cancellation and
installation SHALL race for a single lock-protected claim: when cancellation claims first,
`smb2_set_transport` and `smb2_connect_share_async` SHALL NOT begin and the local bridge SHALL
be closed exactly once; when installation claims first, cancellation SHALL route through the
installed teardown (`teardownSeam()`), which closes exactly once. The install block's first
step SHALL be the lock-protected `localOwned → installing` claim, performed **before any
resource is created**: a failed claim SHALL resume `CancellationError` and return without
constructing the callback pointer (`cbPtr` / `Unmanaged.passRetained(cb)`), without calling
`makeExternalTransport()` (so no `ext.userdata` retain ever exists), and without calling any
libsmb2 API — it therefore has nothing to release. Only after a successful claim SHALL the
block construct `cbPtr`, validate the context, and perform the installation, releasing on each
failure path only the resources actually created by that point. No interleaving SHALL leak a
connected-but-unowned bridge, an unmanaged bridge retain, a continuation, or a registered
libsmb2 operation.

#### Scenario: Cancellation immediately after transport ready

- **WHEN** the task is cancelled while the eager `bridge.connect` is in flight and the
  transport's `.ready` wins its internal connect-outcome claim (design D7), so
  `bridge.connect` returns success while the handoff state is already `cancelled`
- **THEN** the eager-completion reconciliation consumes the cancelled state, closes the
  still-local bridge exactly once, `connectWithBridge` throws `CancellationError`, and no
  libsmb2 call is made and no installation is scheduled

#### Scenario: Transport-internal cancellation error is normalized

- **WHEN** cancellation wins during the eager connect and `bridge.connect` throws the
  transport's internal cancellation error — `POSIXError(.ECANCELED)` from
  `TCPTransportApple`'s mapping, or `CancellationError` from the QUIC D7 machine
- **THEN** the reconciliation consumes the cancelled state, calls `bridge.close()` exactly
  once (idempotent over the transport's own teardown), and the caller observes
  `CancellationError` — never a raw `ECANCELED`; no libsmb2 call is made

#### Scenario: Ordinary eager connect failure

- **WHEN** `bridge.connect` fails while the handoff state is still `eagerConnecting` (no
  cancellation won)
- **THEN** the reconciliation transitions `eagerConnecting → finished`, closes the bridge
  exactly once, and rethrows the mapped original transport error — not `CancellationError`;
  no installation begins and no libsmb2 API is called

#### Scenario: Cancellation racing an ordinary eager failure

- **WHEN** task cancellation and an ordinary `bridge.connect` failure race
- **THEN** the single lock-protected reconciliation decides the winner deterministically:
  cancellation is caller-visible (`CancellationError`) iff its transition to `cancelled`
  committed before the reconciliation claim, otherwise the transport failure is — and exactly
  one path performs `bridge.close()` in either order

#### Scenario: Cancellation before smb2_set_transport

- **WHEN** the task is cancelled after the eager connect returned (bridge locally owned) but
  before the install block claims installation
- **THEN** the cancellation handler closes the local bridge exactly once, and the install
  block's failed first-step claim resumes `CancellationError` and returns without
  constructing the callback pointer, without calling `makeExternalTransport()` (no
  `ext.userdata` retain is ever created, so none needs releasing), without calling
  `smb2_set_transport` or `smb2_connect_share_async`, and `transportBridge` is never set

#### Scenario: Cancellation racing ownership transfer into transportBridge

- **WHEN** cancellation races the install block's lock-protected `installing` claim
- **THEN** exactly one side wins: cancellation-first → the local bridge is closed and no
  libsmb2 connect work begins; installation-first → the install block completes,
  `transportBridge` is assigned, and the serialized teardown closes the installed seam via
  `teardownSeam()` — never both closes, never neither, and the connect continuation is
  resumed exactly once

#### Scenario: Exactly-once close and no libsmb2 connect after a cancellation or eager-failure win

- **WHEN** cancellation or an eager `bridge.connect` failure wins the handoff at any point
  before installation
- **THEN** the bridge's `close()` runs exactly once, no `smb2_set_transport`/
  `smb2_connect_share_async` call is made, no pending operation, continuation, or
  `transportBridge` assignment occurs, and the caller receives `CancellationError` on a
  cancellation win or the mapped transport error on a failure win
- **NOTE** proven deterministically: the internal handoff type's transition table — all
  reconciliation outcomes and both commit orders of the cancellation-versus-failure race — is
  unit-tested directly (no real cancellation timing), and MockTransport-backed
  `connectWithBridge` tests count `close()` calls and assert `transportBridge == nil` with no
  pending operation; a test seam or structural assertion proves a failed install claim
  invoked neither the callback-pointer factory nor `makeExternalTransport()` (design D12;
  tasks 1.5)
