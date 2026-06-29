## Why

The library's documentation consists only of a minimal README.md with outdated examples (points to the upstream `amosavian/AMSMB2` repo, uses old API patterns). There is no architecture documentation, no API reference, and no guidance for AI tools working with the codebase. This makes it hard for new developers to understand the library's design and for AI agents to make correct modifications.

## What Changes

- **Revise README.md**: Update for the simplekube-ro fork, add proper sections (features, requirements, installation, quick start with modern async/await, testing, contributing), fix badge URLs, modernize code examples.
- **Add architecture document** (`docs/ARCHITECTURE.md`): Document the layered design (libsmb2 C → SMB2Client → SMB2FileHandle → SMB2Manager), connection lifecycle, thread safety model, and async operation flow. Include Mermaid flow diagrams for key operations (connect, read/write, copy, monitor).
- **Add API reference** (`docs/API.md`): Comprehensive reference for all public types and methods, organized by domain (connection, file operations, directory operations, streaming, monitoring). Designed for both human readers and AI tool consumption with consistent formatting.
- **Link from README.md**: Add documentation section in README linking to architecture and API docs.

## Capabilities

### New Capabilities
- `readme-revision`: Modernized README with accurate fork information, async/await examples, and documentation links
- `architecture-docs`: Architecture document with Mermaid diagrams covering layered design, thread safety, and operation flows
- `api-reference`: Comprehensive API reference for all public types and methods, structured for human and AI consumption

### Modified Capabilities

## Impact

- **README.md**: Full rewrite
- **docs/ARCHITECTURE.md**: New file
- **docs/API.md**: New file
- **No code changes**: Documentation only
