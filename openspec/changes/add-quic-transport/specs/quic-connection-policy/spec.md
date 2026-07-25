# quic-connection-policy Specification

## ADDED Requirements

### Requirement: QUIC is explicit opt-in only

The library SHALL use the QUIC transport only when the caller explicitly selects
`SMBTransportKind.quic`. `.automatic` SHALL continue to select TCP, and the library SHALL NOT
switch to QUIC based on port number, server capability, or any other heuristic.

#### Scenario: automatic never selects QUIC

- **WHEN** a connection is opened with `.automatic` (including to a server on port 443)
- **THEN** the TCP transport is used

#### Scenario: quic selects the QUIC transport

- **WHEN** a connection is opened with `.quic` on a supported OS version
- **THEN** `QUICTransportApple` is constructed and used for the connection

#### Scenario: quic on an unsupported OS version (manual verification)

- **WHEN** `.quic` is selected on an OS older than the QUIC availability floor
- **THEN** connect throws `POSIXError(.ENOTSUP)`
- **NOTE** CI hosts always satisfy the floor, so the `#unavailable` branch is unreachable in
  unit tests; verified by code inspection (same pattern as the transport-servicing "Deferred to
  T8" notes)

#### Scenario: quic on Linux

- **WHEN** `.quic` is selected on a platform without `Network` (Linux)
- **THEN** `SMB2Manager` throws `POSIXError(.ENOTSUP)` from the transport snapshot it took
  before suspension, **before** constructing any transport or attempting any network activity —
  never a silent downgrade to the legacy TCP path (design D6)
- **NOTE** covered by a Linux unit test run under `make linuxtest`. `POSIXErrorCode` has no
  `.ENOTSUP` case on Linux, so the error surfaces there as the `EOPNOTSUPP` alias of `ENOTSUP`
  (same errno 95); the Linux test asserts `.EOPNOTSUPP` accordingly

#### Scenario: tcp and automatic on Linux use the legacy path unchanged

- **WHEN** `.tcp` or `.automatic` is selected on a platform without `Network` (Linux)
- **THEN** the manager invokes the existing legacy client connect path
  (`connect(server:share:user:)`, the libsmb2-owned socket) exactly as before this change
- **AND** no QUIC-only type requiring Network or Security frameworks participates in Linux
  compilation
- **NOTE** covered by Linux unit tests for both kinds under `make linuxtest`

### Requirement: QUIC rejects all numeric hosts

When `.quic` is selected, the client SHALL reject any target host that the platform resolver
classifies as a numeric IPv4/IPv6 address without DNS — implemented as a `getaddrinfo` probe
with `AI_NUMERICHOST` (`AF_UNSPEC`), not `inet_pton`, so legacy and non-canonical numeric forms
are covered — with `POSIXError(.EINVAL)` and a descriptive message, before any transport object
is constructed and before any network activity. An empty host SHALL also be rejected. The rule
is "**non-numeric hostnames only**" (all numeric hosts are rejected), not "the host must be a
syntactically valid FQDN": `localhost`, single-label names, and other non-numeric names that
fail DNS resolution are accepted by this policy and fail later, at connect. This mirrors the
Samba and Windows SMB-over-QUIC client behavior. The classifier SHALL be exposed internally
(`isNumericHost(_:)`) for table-driven tests.

The rejection table below is **acceptance criteria, not a platform observation**:
`getaddrinfo(AI_NUMERICHOST)` MAY serve as the primary classifier, but if it fails to classify
any required representation as numeric on a supported platform, the classifier SHALL be
supplemented with deterministic parsing for that representation — the requirement SHALL NOT be
weakened to match the platform (design D4). Platform tests may reveal the need for a
classifier supplement; they may not silently weaken the public policy.

Numeric-host rejection SHALL occur before the TLS trust policy is applied and SHALL be
independent of it: `.insecureNoVerification` — which disables certificate-chain validation and
hostname verification — SHALL NOT bypass numeric-host rejection. There is no later validation
layer that would reject a numeric target under an insecure trust policy.

#### Scenario: Numeric hosts rejected (table-driven)

- **WHEN** connecting with `.quic` to any numeric host form, including at minimum:
  `192.168.1.10` (dotted quad), `127.1` (legacy short form), `2130706433` (decimal integer),
  `0x7f000001` (hexadecimal), `0177.0.0.1` (octal), `fe80::1` (IPv6), `[fe80::1]` (bracketed
  IPv6), `fe80::1%en0` (scoped IPv6), `::ffff:192.168.1.10` (IPv4-mapped IPv6)
- **THEN** connect throws `POSIXError(.EINVAL)` before any transport is constructed and no
  network activity occurs
- **NOTE** table-driven unit tests verify the classifier satisfies the required table on every
  supported platform — a platform miss is fixed by supplementing the classifier, never by
  shrinking the table; the connect-path test
  asserts the error is `EINVAL` specifically (a real connect attempt to these targets would
  surface a different error), proving the rejection fired in the validation step that precedes
  transport construction

#### Scenario: Insecure trust policy never bypasses numeric rejection

- **WHEN** connecting with `.quic` to a numeric host (e.g. `192.168.1.10`) with
  `SMBQUICConfiguration(trustPolicy: .insecureNoVerification)`
- **THEN** connect throws `POSIXError(.EINVAL)` before any `NWConnection` is created and
  before any network activity — numeric rejection precedes trust-policy application and is
  independent of it

#### Scenario: Non-numeric hostnames accepted (table-driven)

- **WHEN** connecting with `.quic` to a non-numeric name, including at minimum:
  `fs.example.com`, `localhost`, a single-label name, a name containing digits
  (`1password.example.com`), and a trailing-dot FQDN (`fs.example.com.`)
- **THEN** host validation passes and the QUIC connect proceeds

#### Scenario: TCP is unaffected

- **WHEN** connecting with `.tcp` or `.automatic` to any numeric host
- **THEN** the connection proceeds exactly as before this change

### Requirement: QUIC default port is UDP 443

When `.quic` is selected and the server string carries no explicit port, the client SHALL
default to port 443. An explicit port in the server string SHALL be honored unchanged. Only
ports 1...65535 are valid: an out-of-range explicit port (0, negative, or greater than 65535 —
with no upper bound on the digit string's length) SHALL produce `POSIXError(.EINVAL)` from the
endpoint validation that precedes transport construction, SHALL NOT construct a transport or
reach the `NWConnection` driver factory on the client connect path, and SHALL NOT create an
`NWConnection` — in particular a port above 65535 must never silently truncate to UDP/0.
Endpoint parsing SHALL never trap on an oversized port: digit accumulation stops once the
value is already out of the valid range (no later digit can make it valid again), so an
arbitrarily long digit string parses to an out-of-range value and is rejected with `EINVAL`
like any other. TCP default remains 445, and TCP parsing behavior is unchanged for every
in-range port.

#### Scenario: Default port

- **WHEN** connecting with `.quic` to `fs.example.com`
- **THEN** the transport connects to UDP port 443

#### Scenario: Explicit port honored

- **WHEN** connecting with `.quic` to `fs.example.com:8443`
- **THEN** the transport connects to UDP port 8443

#### Scenario: Out-of-range explicit port rejected

- **WHEN** connecting with `.quic` and an explicit port outside 1...65535 (0, negative, or
  65536 and larger)
- **THEN** connect throws `POSIXError(.EINVAL)` before any transport is constructed, no
  `NWConnection` driver factory is reached, and no `NWConnection` is created (boundary
  ports 1 and 65535 remain accepted and preserved unchanged)

#### Scenario: Oversized explicit port never traps

- **WHEN** connecting with `.quic` (plain or bracketed host form) and an explicit port of
  hundreds of digits (for example `fs.example.com:` followed by 300 `9`s)
- **THEN** endpoint parsing does not trap or crash, connect throws `POSIXError(.EINVAL)`
  before any transport is constructed, and no `NWConnection` driver factory is reached

### Requirement: QUIC connect timeout is dedicated, finite, and always armed

The QUIC connect deadline SHALL be sourced from `SMBQUICConfiguration.connectTimeout`
(default 30 seconds), never from `SMB2Manager.timeout` — `SMB2Manager.timeout` SHALL keep its
existing contract (per-operation timeout; zero or negative disables it; fed to
`smb2_set_timeout` only when positive) unchanged, and the two values SHALL be independent
(design D10). The QUIC connect deadline SHALL NOT be disableable. Before transport construction
and before any network activity, the client SHALL validate and normalize the value through an
internal table-testable helper: `NaN`, infinite, zero, and negative values SHALL throw
`POSIXError(.EINVAL)`; values greater than 3600 seconds SHALL be clamped to 3600; all other
finite positive values (including sub-second) pass through unchanged. The public
`QUICTransportApple(configuration:)` initializer SHALL apply the same normalization, so a
directly constructed transport can never hold an invalid, unnormalized deadline. The value SHALL travel
inside the `SMBQUICConfiguration` snapshot taken under `connectLock` (independently snapshotted
by construction); `copy(with:)` SHALL preserve it and archiving SHALL omit it with the rest of
the configuration (a decoded `.quic` manager gets the 30-second default).

#### Scenario: Default connect timeout

- **WHEN** `.quic` is used with `quicConfiguration == nil` or a configuration that does not set
  `connectTimeout`
- **THEN** the connect deadline is armed at 30 seconds

#### Scenario: Invalid connect-timeout values are rejected deterministically

- **WHEN** `connectTimeout` is `NaN`, `+infinity`, `-infinity`, `0`, or negative and `.quic`
  connect is attempted
- **THEN** connect throws `POSIXError(.EINVAL)` before any transport is constructed and before
  any network activity
- **NOTE** deterministic boundary tests drive the pure normalization helper for every listed
  value — no network involved

#### Scenario: Direct transport construction cannot bypass validation

- **WHEN** `QUICTransportApple(configuration:)` is constructed directly with an invalid
  `connectTimeout` (`NaN`, `±infinity`, zero, or negative)
- **THEN** the initializer throws `POSIXError(.EINVAL)` before any `NWConnection` exists;
  values above 3600 are clamped to 3600 at construction and finite positive values (including
  sub-second) are preserved

#### Scenario: Excessively large values are clamped

- **WHEN** `connectTimeout` is greater than 3600 seconds
- **THEN** the armed deadline is 3600 seconds; `3600` itself passes unclamped and sub-second
  values are honored as-is (boundary-tested)

#### Scenario: Independent of the operation timeout

- **WHEN** `SMB2Manager.timeout` is set to zero or a negative value (its documented
  "disable operation timeouts" contract) and `.quic` connect is attempted
- **THEN** the QUIC connect deadline is still armed from `connectTimeout`, and
  `smb2_set_timeout` behavior after connect is exactly as before this change

### Requirement: No silent transport fallback

When a `.quic` connection attempt fails, the library SHALL surface the error to the caller and
SHALL NOT retry over TCP (or any other transport) on its own. Fallback is the caller's decision.

#### Scenario: QUIC failure propagates

- **WHEN** a `.quic` connect fails (handshake failure, timeout, refused)
- **THEN** the error is thrown to the caller and no TCP connection is attempted

### Requirement: SMB2Manager exposes transport selection

`SMB2Manager` SHALL expose a `transportKind: SMBTransportKind` property (default `.automatic`)
and an optional `quicConfiguration: SMBQUICConfiguration?`. Both SHALL exist on every platform
(the configuration type is platform-neutral, design D5). The transport kind SHALL round-trip
through `NSSecureCoding`/`Codable` with `.automatic` as the decode fallback so existing archives
keep decoding; `quicConfiguration` SHALL NOT be serialized (security-sensitive trust material;
design D6). The new surface is intentionally Swift-only (design D11): `SMBTransportKind` and
`SMBQUICConfiguration` are not Objective-C-representable, the new members SHALL NOT appear in
the generated Objective-C interface (verified by a compile-level header check — no `@nonobjc`
annotation is required because `SMB2Manager` is not `@objcMembers` and the types preclude
`@objc` inference), and the existing Objective-C API SHALL remain source-compatible and
unchanged.

#### Scenario: Default behavior unchanged

- **WHEN** an existing consumer uses `SMB2Manager` without touching the new properties
- **THEN** connections behave exactly as before this change

#### Scenario: Manager-level QUIC opt-in

- **WHEN** `transportKind = .quic` is set before `connectShare`
- **THEN** the underlying client connects using the QUIC transport and policy

#### Scenario: Old archives decode

- **WHEN** an `SMB2Manager` archive created before this change is decoded
- **THEN** decoding succeeds and `transportKind` is `.automatic`

#### Scenario: New surface is absent from the Objective-C interface

- **WHEN** the generated Objective-C interface for the library is inspected (compile-level
  check, design D11)
- **THEN** `transportKind`, `quicConfiguration`, `SMBQUICConfiguration`, and
  `QUICTransportApple` do not appear, and every pre-existing `@objc(...)` entry point is
  unchanged

### Requirement: Connect uses an immutable snapshot of the transport settings

At the start of a connect attempt — under the manager's `connectLock` synchronization boundary
and before any suspension point — `SMB2Manager` SHALL take an immutable value snapshot of
`transportKind` and `quicConfiguration` on every platform. On platforms with `Network` (Apple)
the snapshot SHALL be passed through
`SMB2Client.connect(server:share:user:transportKind:quicConfiguration:)` (a signature that
exists only under `#if canImport(Network)`) into the transport's initializer; on platforms
without `Network` (Linux) the manager SHALL route on the same snapshot (`.quic` → `ENOTSUP`
before any network activity; `.tcp`/`.automatic` → the legacy path; design D6). The transport
SHALL NOT read configuration from the manager or client after construction. Mutating the
properties SHALL never affect a connect attempt already in flight or an established connection;
new values apply to the next connect (design D6).

#### Scenario: Settings change during a connect attempt

- **WHEN** `transportKind` or `quicConfiguration` is mutated while a connect attempt is in
  flight
- **THEN** the in-flight attempt continues with the snapshot it was started with, with no race
  on transport construction

#### Scenario: Settings change while connected

- **WHEN** the properties are mutated on a connected manager
- **THEN** the existing connection is not mutated or torn down; the new values take effect on
  the next `connectShare`

### Requirement: Copying and coding preserve transport settings

`SMB2Manager.copy(with:)` (`NSCopying`) SHALL preserve value snapshots of both `transportKind`
and `quicConfiguration` on the copy. `NSSecureCoding` and `Codable` SHALL round-trip
`transportKind` (via the private string mapping) and SHALL omit `quicConfiguration` — the
copy/serialization asymmetry is deliberate and documented (design D6).

#### Scenario: Copying a QUIC manager

- **WHEN** `copy()` is called on a manager with `transportKind = .quic` and a non-nil
  `quicConfiguration`
- **THEN** the copy has `transportKind == .quic` and an equal `quicConfiguration` value — never
  a silent reversion to `.automatic`/TCP

#### Scenario: Copy is a value snapshot

- **WHEN** the original manager's settings are mutated after `copy()`
- **THEN** the copy's `transportKind`/`quicConfiguration` are unaffected

#### Scenario: Coding round-trip

- **WHEN** a manager with `transportKind = .quic` and a non-nil `quicConfiguration` is archived
  (NSSecureCoding or Codable) and decoded
- **THEN** the decoded manager has `transportKind == .quic` and `quicConfiguration == nil`
  (system-trust default — the safe fallback)
