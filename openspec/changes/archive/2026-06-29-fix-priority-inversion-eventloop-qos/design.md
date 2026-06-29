## Context

`SMB2Client` (in `Context.swift`) creates a serial `DispatchQueue` called `eventLoopQueue` to serialize all libsmb2 context access. The queue is created without an explicit QoS, which defaults to `.default`. Callers of `async_await()` — the core synchronous-bridge method — block on a `DispatchSemaphore` that is signaled from `generic_handler` running on this queue. When the caller runs at `.userInitiated` QoS (the norm for user-driven file operations), the scheduler sees a higher-priority thread waiting on a lower-priority queue — a priority inversion.

## Goals / Non-Goals

**Goals:**
- Eliminate the priority inversion between calling threads and `eventLoopQueue`.
- Silence the Thread Performance Checker diagnostic.
- Ensure the event loop is scheduled promptly relative to its callers.

**Non-Goals:**
- Making QoS caller-configurable via public API (not needed today; `.userInitiated` is correct for all current use cases).
- Changing the threading model or serialization guarantees of `eventLoopQueue`.
- Addressing any other QoS concerns beyond the event loop queue.

## Decisions

### Decision 1: Hard-code `.userInitiated` QoS on `eventLoopQueue`

**Choice**: Set `qos: .userInitiated` in the `DispatchQueue` initializer.

**Alternatives considered**:
- **Propagate caller QoS dynamically** — `DispatchQueue` QoS is set at creation time and cannot be changed per-dispatch. GCD already boosts queue priority temporarily when a higher-QoS thread waits on it, but the Thread Performance Checker still flags the mismatch because the boost is reactive, not proactive.
- **Accept a `DispatchQoS` parameter in `SMB2Client.init`** — Over-engineering for a single correct value. AMSMB2 is always used for user-facing I/O; there is no scenario where `.default` or `.background` would be appropriate.
- **Use `.userInteractive`** — Too aggressive. The event loop processes network replies, not UI rendering. `.userInitiated` matches the semantic: work the user is actively waiting on.

**Rationale**: `.userInitiated` is the correct semantic level. It matches the QoS of callers, eliminates the inversion, and requires no API surface changes.

## Risks / Trade-offs

- **[Minimal] Slightly higher scheduling priority for event loop** → The event loop already runs at elevated priority when GCD detects the inversion reactively. Making it explicit just removes the detection latency and the diagnostic warning. No behavioral change in practice.
- **[Negligible] Future callers at `.background` QoS** → If a future caller deliberately uses `.background`, the event loop will run at a higher QoS than the caller. This is harmless (no inversion, just slightly over-prioritized work) and unlikely given AMSMB2's use cases.
