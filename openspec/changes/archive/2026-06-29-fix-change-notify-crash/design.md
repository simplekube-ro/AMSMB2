## Context

`SMB2Client` in `Context.swift` provides two async operation methods (`async_await` and `async_await_pdu`) that bridge Swift's callback model with libsmb2's C async API. Both methods:

1. Allocate a `CBData` class instance (heap-allocated reference type)
2. Use `withUnsafeMutablePointer(to: &cb)` to get a raw pointer to the **stack-local reference variable**
3. Pass this pointer to a C function as the callback data (`void *cb_data`)
4. Call `wait_for_reply` which polls until the C callback fires and sets `cb.isFinished`

The C callback (`generic_handler`) receives the stored pointer and uses `bindMemory(to: CBData.self).pointee` to recover the `CBData` reference.

**The bug**: `withUnsafeMutablePointer(to:_:)` only guarantees pointer validity within its closure. After the closure returns, the pointer to the stack-local reference is dangling. For Change Notify, `wait_for_reply` blocks for seconds (until a file change occurs), giving the optimizer ample opportunity to invalidate the stack slot.

## Goals / Non-Goals

**Goals:**
- Fix the undefined behavior in callback pointer management for all async operations
- Enable and verify `testMonitor` (Change Notify) against Docker Samba
- Zero regressions in existing tests

**Non-Goals:**
- Changing the overall async operation architecture
- Adding new async operation variants
- Fixing the `notify_change_cb` missing error status propagation (libsmb2 bug, separate issue)

## Decisions

### Use `Unmanaged<CBData>` for pointer management

**Current (broken)**:
```swift
let result = try withUnsafeMutablePointer(to: &cb) { cbPtr in
    try handler(context, cbPtr)  // pointer invalid after closure returns
}
```

**Fixed**:
```swift
let cbPtr = Unmanaged.passUnretained(cb).toOpaque()
let result = try handler(context, cbPtr)
```

**Recovery in `generic_handler`**:
```swift
// Current (broken): bindMemory to pointer-to-reference, then .pointee
let cbdata = try cbdata.unwrap().bindMemory(to: CBData.self, capacity: 1).pointee

// Fixed: direct object recovery from heap pointer
let cbdata = Unmanaged<CBData>.fromOpaque(try cbdata.unwrap()).takeUnretainedValue()
```

**Rationale**: `Unmanaged.passUnretained` creates a raw pointer directly to the heap-allocated `CBData` object. This pointer is valid as long as `cb` (the local variable in `async_await`) holds its strong reference — which it does for the entire method duration including `wait_for_reply`. This is the standard Swift pattern for passing objects through C callback APIs (used in Core Foundation, GCD, etc.).

**Why `passUnretained` not `passRetained`**: The `CBData` object is kept alive by the strong reference `var cb = CBData()` in `async_await`. No ownership transfer is needed. Using `passRetained` would require a matching `takeRetainedValue()` and risk leaks on error paths.

**Alternative considered**: Heap-allocating a separate pointer (`UnsafeMutablePointer<CBData>.allocate`). Rejected — `Unmanaged` is simpler, idiomatic, and doesn't require manual deallocation.

## Risks / Trade-offs

**[Risk] All async operations use this code path** → Mitigated by running the full test suite (52 passing tests) after the change. The fix replaces undefined behavior with defined behavior, so it should be strictly safer.

**[Risk] `generic_handler` is a C function pointer (`smb2_command_cb`)** → The closure is already `@convention(c)` compatible. `Unmanaged` operations are safe to call from C callback context.
