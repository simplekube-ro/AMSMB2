# C char * vs const char * — Swift Import Behavior

## Rule

| C declaration | Swift import | `.map` available? |
|---------------|-------------|-------------------|
| `const char *field` | `UnsafePointer<CChar>?` (optional) | Yes |
| `char *field` (unannotated mutable) | `UnsafeMutablePointer<CChar>` (non-optional) | No |

This distinction is observed on struct fields in Swift 6. Function parameters may differ.

## Null-safe access on mutable `char *` fields

When the underlying C decoder can legally leave a `char *` field as NULL (e.g. NDR null referent IDs), use the bitPattern bridge to get a nullable pointer:

```swift
UnsafePointer<CChar>(bitPattern: UInt(bitPattern: info.netname))
    .map(String.init(cString:)) ?? ""
```

`UnsafePointer<CChar>.init?(bitPattern:)` returns `nil` when the address is zero, enabling the standard `.map ?? ""` idiom.

## Evidence in this codebase

- `srvsvc_SHARE_INFO_1.netname` / `.remark` are `char *` → non-optional → bitPattern bridge required (Parsers.swift)
- `smb2_file_notify_change_information.name` is `const char *` → optional → `.map` works directly (FileMonitoring.swift:174)

## Verified

Compiler error when attempting `.map` on `UnsafeMutablePointer<CChar>`:
"value of type 'UnsafeMutablePointer<CChar>' has no member 'map'"
