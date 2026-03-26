# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AMSMB2 is a Swift library that wraps [libsmb2](https://github.com/sahlberg/libsmb2) to provide SMB2/3 file operations for Apple platforms (iOS 13+, macOS 10.15+, tvOS 14+, watchOS 6+, visionOS 1+) and Linux.

**License note:** The library must be linked dynamically due to libsmb2's LGPL v2.1 license requirements for App Store distribution.

## Build and Test Commands

```bash
# Prerequisites (required after fresh clone)
git submodule update --init

# Build
swift build --disable-sandbox

# Run all tests (unit tests run, integration tests skip without server)
swift test --disable-sandbox

# Run a specific test
swift test --disable-sandbox --filter SMB2ManagerUnitTests/testName

# Integration tests (requires Docker)
make integrationtest

# Linux testing via Docker
make linuxtest              # Uses local volume mount
make cleanlinuxtest         # Clean Docker build
```

## Architecture

### Core Components

- **SMB2Manager** ([AMSMB2.swift](AMSMB2/AMSMB2.swift)) - Public API class, thread-safe, supports NSSecureCoding/Codable. Manages connection lifecycle and exposes all file operations (list, read, write, copy, move, delete).

- **SMB2Client** ([Context.swift](AMSMB2/Context.swift)) - Internal wrapper around libsmb2's `smb2_context`. All access serialized through a dedicated `eventLoopQueue` with `DispatchSource`-based socket monitoring.

- **SMB2FileHandle** ([FileHandle.swift](AMSMB2/FileHandle.swift)) - File handle abstraction for reading/writing. Supports various open modes (read, write, update, overwrite, create).

### Supporting Modules

- [Directory.swift](AMSMB2/Directory.swift) - Directory handle for enumeration
- [Stream.swift](AMSMB2/Stream.swift) - InputStream/OutputStream implementations for streaming I/O
- [Fsctl.swift](AMSMB2/Fsctl.swift) - FSCTL operations (server-side copy via IOCTL)
- [MSRPC.swift](AMSMB2/MSRPC.swift) - MS-RPC protocol for share enumeration
- [ObjCCompat.swift](AMSMB2/ObjCCompat.swift) - Objective-C compatibility layer with completion handler-based APIs
- [FileMonitoring.swift](AMSMB2/FileMonitoring.swift) - Change Notify types (SMB2FileChangeType, SMB2FileChangeAction, SMB2FileChangeInfo)
- [Parsers.swift](AMSMB2/Parsers.swift) - Response parsing — decodes C structs into Swift types
- [Extensions.swift](AMSMB2/Extensions.swift) - URLResourceKey convenience accessors, POSIXError helpers

### Dependencies

- **libsmb2** - C library in `Dependencies/libsmb2/`, compiled as a Swift package target
- **swift-atomics** - Used in tests only

## Specifications & Change Management (OpenSpec)

This project uses [OpenSpec](https://github.com/fission-ai/openspec) for planning and documenting changes.

### Structure

```
openspec/
├── config.yaml                  # Schema config and project context
├── specs/                       # Main specs (accumulated from changes)
└── changes/                     # Active and archived changes
    ├── <change-name>/           # Active change
    │   ├── .openspec.yaml
    │   ├── proposal.md          # Why: problem, what changes, capabilities
    │   ├── design.md            # How: decisions, trade-offs, alternatives
    │   ├── specs/<cap>/spec.md  # What: testable requirements with scenarios
    │   └── tasks.md             # Implementation checklist
    └── archive/                 # Completed changes (YYYY-MM-DD-<name>/)
```

### Workflow

Use the `/opsx:` slash commands to drive the workflow:

| Command | Purpose |
|---------|---------|
| `/opsx:propose` | Create a new change with all artifacts (proposal, design, specs, tasks) |
| `/opsx:apply` | Implement tasks from a change |
| `/opsx:explore` | Think through ideas before proposing |
| `/opsx:archive` | Archive a completed change |

### Guidelines

- **MANDATORY**: All features, bug fixes, and non-trivial changes MUST go through the OpenSpec process (`/opsx:propose` → `/opsx:apply` → `/opsx:archive`). Do not skip proposal/design/specs for any change that touches more than a single file or introduces new behavior. Quick typo fixes and config tweaks are exempt.
- **Review gate**: Every proposal MUST be reviewed by the `project-architect` agent before moving to `/opsx:apply`.
- **Artifacts must reflect implementation**: If the approach changes during implementation, update the proposal, design, and specs to match what was actually shipped.
- **Specs are testable**: Each requirement has scenarios in WHEN/THEN format.
- **Tasks are checkboxes**: Use `- [ ]` / `- [x]` format for tracking.
- **Keep specs honest**: Never archive a change whose specs describe a different approach than what was implemented.
- **Sub-agent implementation pipeline**: When triggering `/opsx:apply`, use sub-agents for implementation in this sequence:
  1. `swift-platform-developer` implements the code changes
  2. `swift-code-reviewer` performs a thorough code review and code simplification
  3. `swift-platform-developer` addresses all findings from the review
  4. `swift-code-reviewer` verifies the fixes are correct

## Development Process — Test-Driven Development (TDD)

**MANDATORY**: All implementation work MUST follow the TDD cycle:

1. **Red** — Write a failing test first that defines the expected behavior
2. **Green** — Write the minimum code to make the test pass
3. **Refactor** — Clean up while keeping tests green

**Rules:**
- Never write implementation code without a corresponding test written first
- Each task from an OpenSpec `tasks.md` should start with writing/updating tests for that task's requirements
- Use the spec scenarios (WHEN/THEN) from OpenSpec as the basis for test cases
- Run tests frequently: `swift test --disable-sandbox` (or `--filter` for targeted runs)
- All tests must pass before marking a task complete

**Exceptions** (TDD not required):
- Configuration/plist/package manifest changes
- Documentation-only changes

## Development Process — Dead Code Prevention

AI agents tend to create unused abstractions and leave orphaned code after refactors:

- **Same-task cleanup**: When replacing code, delete the old symbol/file in the same task — not "later"
- **Code review gate**: Every new type, protocol, extension method, and top-level function must have at least one call site outside its definition file. Exempt: protocol conformance methods, `@objc` entry points
- **Pre-PR sweep**: For each new `.swift` file, verify the primary symbol is referenced elsewhere. For new methods, verify at least one call site

## Token Efficiency

Minimise token usage — this directly affects cost and speed:

- **Don't poll or re-read**: For background tasks, wait for completion once rather than repeatedly reading output files.
- **Skip redundant verification**: After a tool succeeds without error, don't re-read the result to confirm.
- **Match verbosity to task complexity**: Routine ops (merge, simple file edits) need minimal commentary. Save detailed explanations for complex logic, architectural decisions, or when asked.
- **One tool call, not three**: Prefer a single well-constructed command over multiple incremental checks.
- **Don't narrate tool use**: Skip "Let me read the file" or "Let me check the status" — just do it.

## Code Style

The project uses SwiftFormat (`.swiftformat`) and swift-format (`.swift-format`):
- 4-space indentation
- 100/132 character line length
- File headers with MIT license
- LF line endings