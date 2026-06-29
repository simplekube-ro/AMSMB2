## Capability: credential-redaction

Password excluded from all serialization paths; user redacted in debug output.

## Requirements

### R1: Password must not appear in Codable encoding
- `encode(to:)` must NOT encode `_password`
- `init(from:)` must still decode `_password` if present (backward compat) but default to `""`

### R2: Password must not appear in NSSecureCoding encoding
- `encode(with:)` must NOT encode `_password`
- `init?(coder:)` must still decode `_password` if present but default to `""`

### R3: Credentials must not appear in debug output
- `customMirror` must show `"<redacted>"` for the user label
- `customMirror` must NOT include a password entry
- `debugDescription` (which iterates `customMirror.children`) must therefore be credential-free

### R4: customMirror logic bugs must be fixed
- Domain appended only when `!_domain.isEmpty` (not when empty)
- Workstation appended only when `!_workstation.isEmpty` (not when empty)
- Workstation appended exactly once (remove duplicate line)

### R5: NSCopying must preserve password in-memory
- `copy(with:)` must still pass `_password` to the new instance (this is in-memory, not persistence)

## Verification

- Unit test: encode an SMB2Manager via JSONEncoder, decode the JSON, verify password field is absent from JSON and decoded object has empty password
- Unit test: encode via NSKeyedArchiver, decode, verify password is empty
- Unit test: verify `debugDescription` does not contain the username string, contains `<redacted>`
- Unit test: verify customMirror shows domain/workstation only when non-empty, exactly once each
- Unit test: verify `copy(with:)` preserves password
