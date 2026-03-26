## Why

A comprehensive code review identified 10 API correctness issues across the codebase — force-unwraps that crash on unexpected input, logic bugs that silently produce wrong results, inconsistent sentinel values, and silent failures that mask errors. None are concurrency or memory-safety issues (those are addressed by the performance-overhaul); these are straightforward correctness defects in the public and internal API surface.

## What Changes

- **Fix `contents(atPath:range:)` silent empty stream** (AMSMB2.swift:1014): Return `.ENOTCONN` error via continuation instead of silently finishing with empty stream when client is nil
- **Fix `setAttributes` wrong date key** (AMSMB2.swift:577): `.attributeModificationDateKey` case reads `contentModificationDate` instead of `attributeModificationDate` — fix to read the correct key for ctime
- **Fix `smb2_readdir` nil dereference** (Directory.swift:75): `smb2_readdir()` returns nil when directory exhausted; `.pointee` on nil crashes. Use optional chaining.
- **Fix `customMirror` guard polarity** (AMSMB2.swift:87-89): Already covered by `fix-credential-exposure` — skip here to avoid conflict
- **Fix `ShareType` force-unwrap** (Context.swift:920): `ShareType(rawValue:)!` crashes on unknown share types from server. Add `.unknown` case or return optional.
- **Fix `maxWriteSize` sentinel** (FileHandle.swift:302): Returns `-1` on error while `maxReadSize` returns `0`. Align to return `0`.
- **Fix `server!` force-unwrap** (Context.swift:515): `shareEnumSwift` force-unwraps `server` — crashes on disconnected client. Use `try server.unwrap()`.
- **Fix `close()` blocking** (FileHandle.swift:170): Uses synchronous `smb2_close` which blocks indefinitely on unresponsive server. Use async variant with timeout.
- **Fix `url.host!` force-unwrap** (AMSMB2.swift:1456): `connect()` force-unwraps `url.host` — could crash on malformed URLs from NSCoder. Guard with error throw.
- **Fix `removeDirectory` on symlinks** (AMSMB2.swift:1668): Recursive delete calls `rmdir` on directory symlinks, which fails with `ENOTDIR`. Check for `.link` type and use `unlink`.

## Capabilities

### New Capabilities
- `api-safety`: Force-unwraps replaced with safe alternatives; silent failures replaced with proper error propagation; sentinel values made consistent

### Modified Capabilities

## Impact

- **AMSMB2.swift**: 4 fixes (contents stream, setAttributes, url.host, removeDirectory)
- **Context.swift**: 2 fixes (ShareType, server force-unwrap)
- **FileHandle.swift**: 2 fixes (maxWriteSize, close)
- **Directory.swift**: 1 fix (smb2_readdir nil)
- **API surface**: `ShareType` gains `.unknown` case (additive). No other public API changes.
- **Behavioral**: Operations that previously crashed or silently failed now throw appropriate errors.
