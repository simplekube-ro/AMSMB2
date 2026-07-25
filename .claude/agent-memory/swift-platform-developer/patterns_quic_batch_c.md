---
name: patterns-quic-batch-c
description: SMB2Manager transport-selection API (add-quic-transport Batch C) — snapshot/coding/copy/D11 ObjC/Linux routing gotchas
metadata:
  type: project
---

# SMB2Manager transport selection (add-quic-transport Batch C, tasks 3.1–3.4)

Public surface added to `SMB2Manager` (AMSMB2.swift), platform-neutral (NO `#if` on the public
API — `SMBTransportKind`/`SMBQUICConfiguration` are platform-neutral):
- `public var transportKind: SMBTransportKind` (default `.automatic`) + `public var
  quicConfiguration: SMBQUICConfiguration?`. Backing `_transportKind`/`_quicConfiguration` guarded
  by the existing `connectLock` via lock/defer accessors (NSLock never from async — the
  needsReconnect/setClient pattern).
- `func transportSnapshot() -> (kind:, quic:)` — **internal** (not private) so the value-copy
  immutability is unit-testable. Called at the TOP of `connect(shareName:encrypted:)` before any
  suspension (D6). Passed to `SMB2Client.connect(...transportKind:quicConfiguration:)` on Apple.

## Linux ENOTSUP gotcha (compile break — macOS-green ≠ Linux-compiles)
`POSIXErrorCode` has **no `.ENOTSUP` case on Linux** (swift-corelibs-foundation). The manager's
Linux `.quic` rejection can't write `POSIXError(.ENOTSUP)`. Fix: bridge the C errno via the
codebase's `POSIXErrorCode.init(_ code: Int32)` (Extensions.swift): `POSIXError(.init(ENOTSUP),
description:)` + `#if canImport(Glibc) import Glibc` for the `ENOTSUP` macro. Probed values:
Linux `ENOTSUP == EOPNOTSUPP == 95`, and `POSIXErrorCode(rawValue: 95) == .EOPNOTSUPP` (a real
case, NOT the `.ECANCELED` fallback). So Linux tests must assert `.EOPNOTSUPP` (`.ENOTSUP` won't
compile there); Apple's below-floor branch keeps `.ENOTSUP` (Apple-only code, compiles). The whole
Linux `.quic` throw sits in the `#else` of `#if canImport(Network)` in `connect(shareName:)`, so
it fires before `SMB2Client(timeout:)` construction / any network. (Probe the container with
`docker run --rm --entrypoint swift -v "$(pwd)":/home/nonroot/src/app -w …/app linuxtest file.swift`
— a temp .swift copied into the repo dir, since the image entrypoint is `swift test` and only the
repo dir mounts cleanly.)

## Coding (D6): private string mapping, quic never serialized
Add `case transportKind` to `CodingKeys`; two private statics `transportKindCode(_:)->String`
("tcp"/"quic"/"automatic") and `transportKind(fromCode:)->SMBTransportKind` (missing/unknown →
`.automatic`). Do NOT add public RawRepresentable to SMBTransportKind. Both NSSecureCoding
(`aCoder.encode(code, forKey:)` / `decodeObject(of: NSString.self)`) and Codable
(`encode`/`decodeIfPresent(String)`) round-trip transportKind; `quicConfiguration` is NEVER
encoded (decoded `.quic` manager → nil config → system-trust default). `_transportKind` has a
default so inits that don't decode it (designated init?) just get `.automatic`.
Old-archive test (Codable): decode a JSON dict WITHOUT the key → `.automatic`. Old-archive
(NSSecureCoding, Apple-only — NSKeyedUnarchiver differs/SIGTRAPs on Linux): build the archive
manually via `NSKeyedArchiver(requiringSecureCoding:)` omitting the key, decode via
`SMB2Manager(coder: NSKeyedUnarchiver(forReadingFrom:))` with `decodingFailurePolicy =
.setErrorAndReturn`.

## copy(with:) (D6)
Must additionally copy BOTH settings (read via `transportSnapshot()`, assign to the copy's private
backing — same-type access) else a `.quic` manager silently reverts to `.automatic`. Value types →
inherently independent snapshots; test that mutating the original after copy doesn't change the copy.

## D11 Swift-only ObjC posture — runtime verification (executes in CI)
No `@nonobjc` needed (class is `@objc(AMSMB2Manager)` but NOT `@objcMembers`; the new members'
types aren't ObjC-representable → `@objc` can't be inferred). Verified with an Objective-C-runtime
test (Apple-only, `import ObjectiveC`): `SMB2Manager.instancesRespond(to: NSSelectorFromString(
"transportKind"/"setTransportKind:"/"quicConfiguration"/"setQuicConfiguration:"))` all false;
`class_getProperty(SMB2Manager.self, …)` nil; `SMBQUICConfiguration.self is AnyClass` false (struct);
`QUICTransportApple.self is NSObject.Type` false (pure Swift class). A companion test asserts
representative pre-existing `@objc(...)` selectors from ObjCCompat.swift still respond
(connectShareWithName:completionHandler:, disconnectShare, echoWithCompletionHandler:, url, timeout).
Swift-shim guidance for ObjC apps lives as a doc-comment stub on `transportKind` (task 5.1 expands).

Counts: SMB2ManagerTransportSettingsTests = 11 on Apple / 9 on Linux (NSSecureCoding+ObjC Apple-only,
2 routing tests Linux-only). Full suite: 229 macOS / 136 Linux, 0 fail.
