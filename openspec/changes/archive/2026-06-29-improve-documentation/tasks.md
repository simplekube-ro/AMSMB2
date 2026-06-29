## 1. Architecture Document

- [x] 1.1 Create `docs/ARCHITECTURE.md` with layer stack overview and Mermaid diagram
- [x] 1.2 Add connection lifecycle sequence diagram (init → connect → operations → disconnect)
- [x] 1.3 Add async operation flow diagram (Swift async/await → poll loop → callback)
- [x] 1.4 Add thread safety model section (locks, DispatchQueue, concurrent access)
- [x] 1.5 Add source file map table (file → responsibility → layer)

## 2. API Reference

- [x] 2.1 Create `docs/API.md` with type overview section (SMB2Manager, SMB2Client, SMB2FileHandle, etc.)
- [x] 2.2 Add Connection Management methods (init, connectShare, disconnectShare, echo)
- [x] 2.3 Add Share Enumeration methods (listShares)
- [x] 2.4 Add Directory Operations methods (contentsOfDirectory, createDirectory, removeDirectory)
- [x] 2.5 Add File Operations methods (contents, write, append, truncateFile, removeFile, removeItem)
- [x] 2.6 Add File Attributes methods (attributesOfFileSystem, attributesOfItem, setAttributes)
- [x] 2.7 Add Symbolic Links methods (createSymbolicLink, destinationOfSymbolicLink)
- [x] 2.8 Add Copy/Move methods (copyItem, moveItem)
- [x] 2.9 Add Upload/Download methods (uploadItem, downloadItem)
- [x] 2.10 Add Streaming and Monitoring methods (write stream, monitorItem)
- [x] 2.11 Add Common Errors section
- [x] 2.12 Add SMB2Client and SMB2FileHandle public API sections

## 3. README Revision

- [x] 3.1 Rewrite README.md with fork identification, features, requirements, and installation
- [x] 3.2 Add modern async/await quick start examples (connect, list, read, write)
- [x] 3.3 Add testing section (unit tests, integration tests, submodule prereq)
- [x] 3.4 Add documentation links section pointing to ARCHITECTURE.md and API.md
- [x] 3.5 Update license section and badge URLs for the fork
