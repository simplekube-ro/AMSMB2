## Why

The `expose-smb2-internals` branch makes `SMB2Client`, `SMB2FileHandle`, and related members public so downstream packages can use the raw file handle API directly. A security review identified 11 findings (1 critical, 3 high, 4 medium, 3 low) — most are pre-existing concurrency and memory safety bugs that were previously unreachable because the types were internal. Making them public promotes these latent bugs to exploitable surface area.

## What Changes

- Fix use-after-free: two call sites in `FileHandle.swift` access `client.context` without acquiring `_context_lock`, causing a race with `disconnect`/`service` that destroys the context
- Fix double-close race: `close()` and `deinit` race on the `handle` optional without synchronization — add locking to prevent data race and C-level double-free
- Fix TOCTOU on `smbClient` getter: acquire `connectLock` and validate connection state, not just `client != nil`
- Make `context` field `private` on `SMB2Client` to compiler-enforce the lock discipline
- Remove `public` from `smb2fh` typealias — raw `OpaquePointer` should not be stable public API
- Mark `SMB2Client.init` explicitly `internal` to prevent accidental future promotion
- Add documentation on thread-safety contracts for all newly-public members

## Capabilities

### New Capabilities
- `thread-safe-context-access`: Enforce that all `smb2_context` access goes through `withThreadSafeContext`, making the lock discipline compiler-verified via `private` access control
- `safe-file-handle-lifecycle`: Synchronized file handle close/deinit to prevent double-close races, with explicit documentation of ownership semantics
- `validated-client-accessor`: `smbClient` getter that validates both existence and connection state under `connectLock`

### Modified Capabilities

## Impact

- **Files modified**: `Context.swift`, `FileHandle.swift`, `AMSMB2.swift`
- **API surface**: `smb2fh` typealias reverts to internal; all other public additions from `expose-smb2-internals` are preserved
- **Behavioral**: No change for correct single-threaded usage; concurrent usage becomes safe rather than UB
- **Breaking**: Removing `public` from `smb2fh` is a **BREAKING** change relative to `expose-smb2-internals`, but that branch has not been released
