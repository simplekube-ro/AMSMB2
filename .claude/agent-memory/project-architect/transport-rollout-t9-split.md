---
name: Transport rollout T9 Apple/Linux split
description: Legacy DispatchSource path is currently UNGUARDED; T9 must guard-not-delete for Linux
type: project
---

The pluggable-TCP-transport rollout (openspec/changes/add-pluggable-tcp-transport) flips the
Apple default to the NIO seam in T9 and "removes the legacy DispatchSource path."

**Critical fact:** As of branch feat/tcp-transport-rollout, the legacy socket code in
AMSMB2/Context.swift is NOT behind any platform guard — it compiles on ALL platforms. Only the
seam code is behind `#if canImport(Network)`. So T9.3 "remove" on Apple = wrap legacy code in
`#else` of the existing `#if canImport(Network)` (Linux-only), NOT literal deletion.

**Why:** Linux has no `TCPTransportApple` (NIOTransportServices is Network.framework-backed,
Apple-only). Linux MUST keep the libsmb2-owned TCP DispatchSource path as its only transport.

**How to apply:** Symbols that must survive under `#if !canImport(Network)` (over-deletion breaks
the Linux build, which is INVISIBLE in the Apple-only sandbox here — Apple build stays green):
SocketMonitor class, socketMonitor property, startSocketMonitoring(), stopSocketMonitoring(),
handleSocketEvent(), activateWriteSourceIfNeeded, pollUntilComplete(_:), and the legacy
connect(server:share:user:) at ~line 536. `CBData.isFinished` is written by the SHARED
generic_handler (used by both paths) and read only by pollUntilComplete → on Apple it becomes
write-only (acceptable; keep unguarded). The flip point is SMB2Manager.connect(shareName:encrypted:)
at AMSMB2.swift:1498 which calls client.connect(server:share:user:) — on Apple route to
client.connect(...,transportKind: .automatic).

Docker is unavailable in the sandbox so T8 acceptance (full Samba suite through the seam) cannot
be greened locally; the flip+removal must stay on-branch/unmerged until a human runs T8 green.
