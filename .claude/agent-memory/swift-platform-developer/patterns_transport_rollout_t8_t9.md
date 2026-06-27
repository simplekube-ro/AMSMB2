# Transport Rollout T8 (#27) + T9 (#28)

## T8 env toggle (AMSMB2Tests/TestUtilities.swift, SMBIntegrationTestCase)
- `SMB_TRANSPORT` env read alongside `SMB_SERVER`. Pure `static transportKind(forEnvValue:) -> SMBTransportKind?`
  mapping (unit-testable without env mutation): unset/`legacy`/unknown → nil; `seam`/`tcp`/`auto`/`automatic` → `.automatic`.
  Lazy `transportKind` prop + `usesSeamTransport` Bool.
- Helpers: `makeConnectedClient(...)` (raw SMB2Client; Apple always seam via `transportKind ?? .automatic`,
  Linux legacy under `#else`), `makeConnectedManager(...)`. `serverHost` = host:port from `server` URL.
- Unit test the mapping in a plain `XCTestCase` (SMBTransportToggleTests) — runs, not skipped. Seam acceptance
  tests inherit SMBIntegrationTestCase + gate `XCTSkipUnless(usesSeamTransport)` and `#if !canImport(Network)` skip.
- Acceptance matrix (connect/auth/list/large-IO/cancel) only validates against live Samba+Docker → DEFER green run.
  `fileDescriptor == -1` is the deterministic seam-signature assertion (naming trap: AUTO not TCP).

## T9 guard-not-delete (AMSMB2/Context.swift) — CRITICAL to avoid invisible Linux breakage
- The legacy socket path was UNGUARDED (compiled everywhere). Flip moves it under `#else` of `#if canImport(Network)`
  so it compiles ONLY on Linux. Guard, NEVER delete (sandbox is Apple-only; deleting still builds green on Apple
  but silently breaks Linux which has no other transport).
- Linux-only symbols wrapped in `#if !canImport(Network)`: `socketMonitor` prop, `SocketMonitor` class,
  `handleSocketEvent`, `startSocketMonitoring`, `stopSocketMonitoring`, `pollUntilComplete`, legacy `connect(server:share:user:)`.
- Restructure onto paired `#if canImport(Network) … seam … #else … legacy … #endif`: `shutdown()`,
  `activateServicingAfterOperation()`, `disconnect()`. One transport path per platform → deterministic dead-code sweep.
- `CBData.isFinished` + its write in shared `generic_handler` stay UNGUARDED (seam reuses generic_handler);
  write-only on Apple, consumed only by Linux `pollUntilComplete`. Document it so reviewers don't flag dead code.
- T9.2 flip: `SMB2Manager.connect(shareName:encrypted:)` (AMSMB2.swift) → `client.connect(...,transportKind:.automatic)`
  under `#if canImport(Network)`, legacy under `#else`.
- Baseline warnings: 4 SendableClosureCaptures in Context.swift async_await (cbPtr/handler) are PRE-EXISTING.
  "must restate inherited '@unchecked Sendable'" warns on every SMBIntegrationTestCase subclass (e.g. SMB2ManagerTests)
  — pre-existing category; match convention (non-final `class`, no restatement) rather than silencing.

## CI (8.4)
- `make seamintegrationtest` = `SMB_TRANSPORT=seam ./scripts/test-integration.sh` (script re-exports SMB_TRANSPORT, default legacy).
- `.github/workflows/integration.yml`: macOS + Colima Docker, `[legacy, seam]` matrix. Authored, NOT run here (needs Docker).
