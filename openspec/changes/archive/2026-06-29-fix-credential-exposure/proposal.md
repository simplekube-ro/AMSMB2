## Why

A code review identified that `SMB2Manager` serializes the user's password through both `Codable` and `NSSecureCoding` encoding paths. Any caller that archives or JSON-encodes the manager (a natural use of these conformances) stores the credential in plaintext on disk. Additionally, `customMirror` exposes `_user` as a labeled child, meaning `print(manager)` or `po manager` in a debugger emits the username. The mirror also has inverted guard conditions (appending domain/workstation only when *empty*) and a duplicate `workstation` line.

These are pre-existing issues in the upstream AMSMB2 library, but they become a real concern for any app that persists connection configurations.

## What Changes

- **Omit `_password` from all encoding paths**: Remove password from `encode(with:)` (NSCoder), `encode(to:)` (Codable), and `init(from:)` (Codable decoding). After decoding, the password field is empty — callers must re-supply credentials. This is a **BREAKING** behavioral change for any code that round-trips SMB2Manager through Codable/NSCoding and expects the password to survive.
- **Redact credentials in `customMirror`**: Replace `_user` with `"<redacted>"`. Do not expose `_password` at all (it isn't currently, but guard against future additions).
- **Fix `customMirror` logic bugs**: Invert the guard conditions (`!_domain.isEmpty`, `!_workstation.isEmpty`), remove the duplicate `workstation` line.
- **Add `_password` deprecation note**: Document in the CodingKeys or a comment that password is intentionally excluded from serialization for security.

## Capabilities

### New Capabilities
- `credential-redaction`: Password excluded from all serialization paths (Codable, NSSecureCoding); user redacted in debug output (customMirror, debugDescription)

### Modified Capabilities

## Impact

- **AMSMB2.swift**: `encode(with:)`, `encode(to:)`, `init(from:)`, `init?(coder:)`, `customMirror` modified
- **API surface**: **BREAKING** — code that encodes then decodes an SMB2Manager will lose the password. This is intentional and correct.
- **Behavioral**: `debugDescription` and `print()` output changes (no more username visible)
- **No other files affected**
