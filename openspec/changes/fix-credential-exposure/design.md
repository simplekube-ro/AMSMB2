## Context

`SMB2Manager` conforms to `NSSecureCoding`, `Codable`, `NSCopying`, and `CustomReflectable`. The `_password` field is a `fileprivate` stored property that is currently encoded/decoded through both NSCoder and Codable paths. The `customMirror` property exposes `_user` directly.

## Goals / Non-Goals

**Goals:**
- Eliminate password persistence in all serialization formats
- Redact credentials in debug/reflection output
- Fix the inverted guard logic and duplicate line in `customMirror`
- Maintain backward compatibility for decoding (old archives that contain a password should still decode, just ignoring the password field)

**Non-Goals:**
- Keychain integration (that's a consumer concern, not a library concern)
- Encrypting credentials in memory (out of scope)
- Changing `NSCopying` behavior (`copy(with:)` copies the live object including password — this is in-memory, not persistence)

## Decisions

### D1: Omit password from encoding, tolerate it in decoding

**Choice**: In `encode(with:)` and `encode(to:)`, skip `_password`. In `init?(coder:)` and `init(from:)`, still read the password key if present (for backward compat with existing archives) but default to empty string. This means old archives decode without error but the password field is empty.

**Rationale**: Hard failure on old archives would be worse than requiring re-authentication. Consumers can detect the empty password and prompt.

### D2: Redact user in customMirror, omit password entirely

**Choice**: Show `"<redacted>"` for the user label. Do not add a password entry to the mirror under any circumstance.

**Alternative considered**: Omit user entirely from mirror. Rejected because the mirror is useful for debugging connection issues — knowing *that* a user is set (even if redacted) is valuable.

### D3: Fix customMirror guard polarity inline

**Choice**: Fix the `if _domain.isEmpty` → `if !_domain.isEmpty` and `if _workstation.isEmpty` → `if !_workstation.isEmpty` inversions, and remove the duplicate workstation line, as part of this change rather than a separate one.

**Rationale**: These are in the same method, same review scope, 3-line fix. No reason to separate.

## Risks / Trade-offs

**[Risk] Breaking change for consumers that persist SMB2Manager** → Mitigated by: (a) decoding still works, just yields empty password; (b) this is a security fix, the old behavior was a vulnerability; (c) document in release notes.

**[Trade-off] `copy(with:)` still copies password in memory** → Acceptable. In-memory copy is transient and expected. Serialization to disk is the threat model.
