## Context

AMSMB2 is a Swift SMB2/3 client library wrapping libsmb2. The simplekube-ro fork has added public API exposure (SMB2Client, SMB2FileHandle), security hardening, and a comprehensive test infrastructure. The current README still references the upstream repo and uses outdated patterns.

The library has ~101 public API members across 6 files, a clear layered architecture (C → Swift wrapper → public API), and specific thread safety patterns that need documenting.

## Goals / Non-Goals

**Goals:**
- README that accurately represents the fork with modern async/await examples
- Architecture doc with Mermaid diagrams showing the layer stack, connection lifecycle, and async operation flow
- API reference that serves both human developers and AI coding assistants
- All docs linked from README for discoverability

**Non-Goals:**
- Auto-generated documentation (DocC, Jazzy) — too much infrastructure for the current project stage
- Tutorial/cookbook-style guides — the API reference and examples in README are sufficient
- Documenting internal/private APIs — focus on the public surface only
- Documenting the ObjC compatibility layer — it mirrors the Swift API

## Decisions

### 1. Mermaid for diagrams

Use Mermaid syntax in the architecture document. GitHub renders Mermaid natively in markdown, making the diagrams viewable without external tools. AI tools can also read and reason about Mermaid source.

### 2. API reference format

Use a consistent markdown format per method:

```
### `methodName(param:param:)`
Description.
- **Parameters:** ...
- **Returns:** ...
- **Throws:** ...
```

Group methods by domain (Connection, File Operations, Directory Operations, etc.). This structure is easy for both humans to scan and AI agents to parse for context.

### 3. Separate architecture from API

Architecture doc covers the "why" and "how" (design decisions, data flow, thread safety). API doc covers the "what" (every public method, its parameters, its behavior). This separation keeps each document focused and at a manageable length.

### 4. README structure

Follow the standard open-source README pattern: badges → overview → features → requirements → installation → quick start → testing → documentation links → license.

## Risks / Trade-offs

**[Risk] Documentation drift** → Mitigated by keeping docs focused on stable public API. CLAUDE.md already documents architecture for AI agents, so these docs complement rather than duplicate.

**[Trade-off] Manual API docs vs auto-generated** → Manual docs are more readable and can include context/examples, but require maintenance. Acceptable for a library of this size (~101 public members).
