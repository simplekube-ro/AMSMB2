## Context

These are 10 independent correctness fixes identified during a comprehensive code review. They share no architectural dependency — each is a localized bug fix. Grouping them in one change is for review efficiency, not because they're coupled.

## Goals / Non-Goals

**Goals:**
- Eliminate all force-unwraps that can crash on valid (but unexpected) input
- Replace silent failures with proper error propagation
- Fix logic bugs that produce wrong results
- Make sentinel values consistent across the API

**Non-Goals:**
- Concurrency fixes (covered by performance-overhaul)
- Memory safety fixes (covered by performance-overhaul)
- Credential fixes (covered by fix-credential-exposure)
- Parser fixes (covered by fix-parser-robustness)

## Decisions

### D1: `ShareType` — add `.unknown` case rather than return optional

**Choice**: Add `case unknown` with a large raw value, and change the computed property to return `.unknown` instead of force-unwrapping. This avoids making the return type optional, which would be a larger API change.

**Alternative**: Return `ShareType?`. Rejected because existing callers switch on `ShareType` and would need `case nil:` handling everywhere.

### D2: `contents(atPath:)` — throw via continuation, not return

**Choice**: When `client` is nil, call `continuation.finish(throwing: POSIXError(.ENOTCONN))` instead of silently returning. This matches the error behavior of all other API methods.

### D3: `close()` — use fire-and-forget async close instead of blocking sync

**Choice**: Replace `smb2_close(context, handle)` with the same `fireAndForget` pattern used in `deinit`. The close PDU is sent but the caller doesn't block waiting for the server's response. If the server is unresponsive, the close still returns immediately.

**Alternative**: Use `smb2_close_async` with a timeout. More complex and the benefit over fire-and-forget is marginal — close doesn't return meaningful data.

### D4: `removeDirectory` — check `isLink` before choosing rmdir vs unlink

**Choice**: In the recursive deletion loop, check `item.isLink` first (before `isDirectory`). Symlinks to directories report `isDirectory == true` but must be `unlink`-ed, not `rmdir`-ed.

### D5: `setAttributes` — fix key to `attributeModificationDate`

**Choice**: Change `attributes.contentModificationDate` to `attributes.attributeModificationDate` in the `.attributeModificationDateKey` case. This is a straightforward bug fix — the wrong dictionary key was being read.

## Risks / Trade-offs

**[Risk] `ShareType.unknown` is additive but changes exhaustive switch behavior** → Any consumer with `switch shareType` will get a compiler warning if not handling `.unknown`. This is desirable — they should handle unknown types.

**[Risk] `close()` fire-and-forget means close errors are silently ignored** → This is already the behavior in `deinit`. Close errors from SMB servers are rare and generally not actionable by the caller.
