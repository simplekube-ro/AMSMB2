# Swift 6 — C Function References as Variables

## Problem: Global `let` C Function Aliases Fail Strict Concurrency

When writing compile-time smoke tests that assign a C function to a typed alias,
**placing it at file scope (global `let`)** triggers Swift 6 errors:

```
error: let 'foo' is not concurrency-safe because non-'Sendable' type
'(UnsafeMutablePointer<T>?) -> Int32' may have shared mutable state
[#MutableGlobalVariable]
```

Root cause: unannotated function types are not `Sendable`. Even though C functions
imported from a C module are themselves `@Sendable`, the type annotation without
`@Sendable` creates a mismatch that Swift 6 treats as a mutable global.

## Solution: Move Aliases Inside Test Methods as Local Variables

Local variables (inside a function body) are not shared state, so no concurrency
checks apply. Use `@Sendable` on the type annotation to match what the compiler
infers for C-imported functions:

```swift
// WRONG — global let, fails Swift 6
private let _setTransport: (UnsafeMutablePointer<smb2_context>?, Int32, ...) -> Int32
    = smb2_set_transport

// CORRECT — local variable inside a test method
func testSMB2SetTransportIsImportable() {
    let functionRef: @Sendable (
        UnsafeMutablePointer<smb2_context>?, Int32,
        UnsafePointer<smb2_external_transport>?
    ) -> Int32 = smb2_set_transport
    XCTAssertNotNil(functionRef as Any)
}
```

The local variable is resolved at compile time — if the symbol is absent the test
file fails to compile, which is the desired regression-detection behavior.

## Pattern for Smoke Tests

For each C function you want to verify is importable:
1. Write a dedicated `func test<FunctionName>IsImportable()` test
2. Create a local `let functionRef: @Sendable (...) -> ReturnType = cFunctionName`
3. Use `XCTAssertNotNil(functionRef as Any)` for a trivially true runtime check
   (the real value is compile-time symbol resolution)
