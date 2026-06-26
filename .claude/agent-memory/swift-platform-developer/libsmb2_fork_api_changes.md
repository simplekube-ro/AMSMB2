# libsmb2 Fork API Changes (simplekube-ro/libsmb2)

## Submodule Setup

The `Dependencies/libsmb2` submodule targets `https://github.com/simplekube-ro/libsmb2`
(fork of `sahlberg/libsmb2`) pinned at SHA `944f7d15a7dabab7d3123f9d5f434c1ef29fa8aa`
(master head after PR #40 — full in-memory exchange test).

To re-initialize after a fresh clone:
```
git submodule sync Dependencies/libsmb2
git submodule update --init Dependencies/libsmb2
```

## Package.swift Exclusions

The fork adds `lib/dreamcast/` (Dreamcast console port, requires `kos.h` — not present on
macOS/Linux). It must be excluded alongside the existing `lib/ps2` exclusion:

```swift
exclude: [
    ...
    "lib/ps2",
    "lib/dreamcast",   // required for fork
],
```

## C Struct Renames (fork vs upstream)

### srvsvc share enumeration (libsmb2-dcerpc-srvsvc.h)

| Upstream (sahlberg) | Fork (simplekube-ro) |
|---|---|
| `srvsvc_SHARE_INFO_1_carray` | `srvsvc_SHARE_INFO_1_CONTAINER` |
| `.max_count` | `.EntriesRead` |
| `ses.ShareInfo.Level1.Buffer.pointee` | `ses.ShareEnum.Level1` (is already the container) |
| `netname.utf8` / `remark.utf8` (smb2_utf16*) | `netname` / `remark` (plain `char*`) |

### Swift adaptation in Parsers.swift

The fork's `netname`/`remark` fields are `char *` PTR_UNIQUE NDR referents. Swift imports
unannotated struct `char *` fields as non-optional `UnsafeMutablePointer<CChar>` (NOT Optional),
but the C decoder leaves them as a null pointer (calloc zero) when the server sends a null NDR
referent ID (legal for `remark`). Passing a null non-optional pointer to `String(cString:)` traps.

**Guard pattern for non-optional C pointers that may be null at the memory level:**
```swift
// WRONG — traps when pointer is null even though type says non-optional
name: String(cString: info.netname)

// CORRECT — UnsafePointer<T>.init?(bitPattern:) returns nil when address == 0
name: UnsafePointer<CChar>(bitPattern: UInt(bitPattern: info.netname))
    .map(String.init(cString:)) ?? ""
```

Full adapted init (Parsers.swift):
```swift
init(_ container: srvsvc_SHARE_INFO_1_CONTAINER) {
    self = [srvsvc_SHARE_INFO_1](
        UnsafeBufferPointer(start: container.share_info_1, count: Int(container.EntriesRead))
    ).map { info in
        SMB2Share(
            name: UnsafePointer<CChar>(bitPattern: UInt(bitPattern: info.netname))
                .map(String.init(cString:)) ?? "",
            props: .init(rawValue: info.type),
            comment: UnsafePointer<CChar>(bitPattern: UInt(bitPattern: info.remark))
                .map(String.init(cString:)) ?? ""
        )
    }
}
```

Two unit tests in `SMB2ParserTests` cover the null-guard:
`testShareContainerWithNullRemark` / `testShareContainerWithNullNetname`.
They use zero-initialized `srvsvc_SHARE_INFO_1()` structs (calloc-zero = null pointer).

## New Transport API (fork-only)

The fork adds these symbols visible via `import SMB2`:
- `smb2_set_transport(context, transport_type, ext_transport)`
- `smb2_external_transport` struct (connect/send/recv/close callbacks + userdata)
- `SMB2_TRANSPORT_TCP` = 0, `SMB2_TRANSPORT_QUIC` = 1, `SMB2_TRANSPORT_AUTO` = 2
- `smb2_get_timeout(context)` / `smb2_service_timeout(context)`
- `transport-external.c` and `timer.c` are new source files (compiled automatically)

**Naming trap**: To route through the external transport seam, use `SMB2_TRANSPORT_QUIC` or
`SMB2_TRANSPORT_AUTO` — never `SMB2_TRANSPORT_TCP` which selects libsmb2's built-in socket.

**Swift signatures** (as imported by Swift 6):
```swift
smb2_set_transport:    @Sendable (UnsafeMutablePointer<smb2_context>?, Int32, UnsafePointer<smb2_external_transport>?) -> Int32
smb2_get_timeout:      @Sendable (UnsafeMutablePointer<smb2_context>?, UnsafeMutablePointer<timeval>?) -> Int32
smb2_service_timeout:  @Sendable (UnsafeMutablePointer<smb2_context>?) -> Int32
```

**Module map note**: `Dependencies/libsmb2/include/module.modulemap` already includes
`smb2/libsmb2.h` in the `SMB2.LibSMB2` submodule — no module map changes are needed to
expose transport-seam symbols. Tests access these via `import SMB2` transitively.

**Smoke test**: `AMSMB2Tests/SMB2TransportSymbolTests.swift` — compile-time + runtime
regression guard for all five transport symbols and all struct fields.
