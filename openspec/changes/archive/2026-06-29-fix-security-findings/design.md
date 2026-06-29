## Context

AMSMB2 wraps libsmb2 (a single-threaded C library) for Apple platforms. The `expose-smb2-internals` branch makes `SMB2Client` and `SMB2FileHandle` public so downstream packages can use the raw file handle API. A security review found that several pre-existing concurrency and memory safety bugs — previously unreachable because these types were internal — become exploitable through the new public surface.

Key architectural constraints:
- libsmb2 requires all operations on a single `smb2_context` to happen from one thread at a time
- `SMB2Client` enforces this via `_context_lock` (`NSRecursiveLock`) and `withThreadSafeContext()`
- `SMB2Manager` manages client lifecycle via `connectLock` (`NSLock`) and a `fileprivate var client: SMB2Client?`
- `SMB2FileHandle` holds a reference to its parent `SMB2Client` and wraps a C `smb2fh` pointer

## Goals / Non-Goals

**Goals:**
- Fix all Critical and High severity findings from the security review
- Address Medium findings where the fix is straightforward
- Preserve the existing public API contract from `expose-smb2-internals`
- Keep changes minimal — fix the safety issues without redesigning the architecture

**Non-Goals:**
- Redesigning the concurrency model (e.g., converting to actors)
- Adding async/await APIs or structured concurrency
- Adding disconnection notification/delegate patterns (MEDIUM-2 — deferred)
- Fixing the blocking `deinit` in `SMB2FileHandle` (LOW-2 — pre-existing, low risk)

## Decisions

### D1: Make `context` private, route all access through `withThreadSafeContext`

The two lockless call sites in `FileHandle.swift` (lines 97, 205) access `client.context` directly. Both `smb2_fh_from_file_id` and `smb2_lseek` are synchronous C calls that can be wrapped in `withThreadSafeContext`.

**Alternative considered:** Adding a second lock in `SMB2FileHandle` — rejected because it would create lock ordering issues with the existing `_context_lock`.

### D2: Add `NSLock` to protect `SMB2FileHandle.handle` optional

The `handle` field is read/written by both `close()` and `deinit` without synchronization. A lightweight `NSLock` (not recursive — no reentrancy needed here) guards the swap-to-nil pattern in both sites.

**Alternative considered:** Using `OSAllocatedUnfairLock<smb2fh?>` — rejected for compatibility (requires macOS 13+/iOS 16+, but AMSMB2 targets macOS 10.15+/iOS 13+).

### D3: Acquire `connectLock` in `smbClient` getter + validate connection state

The getter currently only checks `client != nil`. It must also check `client.fileDescriptor != -1` (which reads `smb2_get_fd` — a fast, non-blocking check) to catch the case where the client exists but the context has been destroyed.

Acquiring `connectLock` prevents the TOCTOU race where `disconnectShare` sets `self.client = nil` between the nil check and the return.

**Alternative considered:** Documenting the stale-reference risk instead of fixing it — rejected because consumers would need deep knowledge of the library internals to use it safely.

### D4: Revert `smb2fh` to internal

`smb2fh` is a typealias for `OpaquePointer`. No public API takes or returns it directly. Exposing it creates a false affordance. Reverting to `internal` has no impact on downstream consumers.

### D5: Mark `SMB2Client.init` explicitly `internal`

Defensive code hygiene — prevents accidental promotion in future PRs.

## Risks / Trade-offs

- **[Risk] `connectLock` contention in `smbClient` getter** → The lock is only held for the duration of a nil-check and pointer read (nanoseconds). No observable performance impact. Mitigation: the lock is already used in `connectShare`/`disconnectShare` with the same granularity.

- **[Risk] `withThreadSafeContext` wrapping `smb2_lseek` changes error semantics** → Currently `smb2_lseek` is called directly and `POSIXError.throwIfError` handles failures. Wrapping it in `withThreadSafeContext` means a nil context now throws the unwrap error instead of crashing on a nil pointer. This is strictly better behaviour.

- **[Risk] Adding `NSLock` to `SMB2FileHandle` increases per-handle allocation** → Negligible (one lock per file handle). File handles are heavyweight objects backed by C allocations; one more lock is immaterial.

- **[Trade-off] No disconnection notification** → Consumers of `smbClient` still get opaque errors when a session tears down. A proper fix requires a delegate/notification pattern that is out of scope for this change. Documented as a known limitation.
