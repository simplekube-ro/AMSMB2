# swift-platform-developer memory (AMSMB2)

## Build / test

- Always `--disable-sandbox`: `swift build --disable-sandbox`, `swift build --disable-sandbox --build-tests`,
  `swift test --disable-sandbox --filter <Suite>/<test>`.
- `swift build` prints a giant frontend command line on failure — grep for `error:` instead of
  reading the tail.
- Full unit run baseline (no `SMB_SERVER`/`SMB_QUIC_SERVER`): ~291 executed, ~69 skipped,
  0 failures. All skips are server-gated; a non-server-gated skip is a real problem.
- No Docker on this host: `make integrationtest` / `make linuxtest` cannot run here. Record that
  rather than claiming a pass.

## Swift 6 gotchas hit in this repo

- A `static var` counter guarded by an `NSLock` still needs `nonisolated(unsafe)` under Swift 6
  ("not concurrency-safe because it is nonisolated global shared mutable state"). Acceptable when
  EVERY access goes through the lock — say so in a comment. Precedent: `CBData.liveCount`.
- Capturing a mutable `var client: SMB2Client?` in a `Task { }` is rejected; capture by value with
  `Task { [client] in ... }`, then `client = nil` later to drop the last reference (pattern used
  throughout `SMB2CBDataLifetimeTests` / `SMB2DisconnectReclaimTests`).
- Test files need `import SMB2` to call `smb2_*` C symbols; they are not re-exported through
  `@testable import AMSMB2`.

## Context.swift lifetime model

See [disconnect-reclaim.md](disconnect-reclaim.md) for the CBData / context ownership rules.
