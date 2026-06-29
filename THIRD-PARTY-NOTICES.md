# Third-Party Notices

AMSMB2 is distributed with, links against, or is derived from the third-party
components listed below. Each retains its own license; the notices here are
recorded alongside the libsmb2 LGPL v2.1 text shipped in [`LICENSE`](LICENSE).

## AMSMB2 (this library)

- **License:** MIT (see the per-file headers in `AMSMB2/`).
- AMSMB2 is a fork of [amosavian/AMSMB2](https://github.com/amosavian/AMSMB2)
  by Amir Abbas Mousavian, also MIT licensed.

## libsmb2

- **Project:** [simplekube-ro/libsmb2](https://github.com/simplekube-ro/libsmb2),
  a fork of [sahlberg/libsmb2](https://github.com/sahlberg/libsmb2) that adds a
  pluggable external-transport C API.
- **License:** GNU Lesser General Public License v2.1 (LGPL-2.1). The full text
  is the [`LICENSE`](LICENSE) file in this repository.
- **Distribution note:** Because of the LGPL-2.1 terms, applications that bundle
  AMSMB2 for App Store distribution **must link the library dynamically**. The
  framework is configured as `.dynamic` in `Package.swift` to comply.

## SwiftNIO

- **Project:** [apple/swift-nio](https://github.com/apple/swift-nio) (`NIOCore`).
- **License:** Apache License 2.0 — full text at
  <https://github.com/apple/swift-nio/blob/main/LICENSE.txt>.
- **Scope:** Apple platforms only. All usage is guarded by
  `#if canImport(Network)`; the Linux build pulls in no NIO transport code.

## SwiftNIO Transport Services

- **Project:** [apple/swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services)
  (`NIOTransportServices`) — a Network.framework-backed NIO transport.
- **License:** Apache License 2.0 — full text at
  <https://github.com/apple/swift-nio-transport-services/blob/main/LICENSE.txt>.
- **Scope:** Apple platforms only. Backs `TCPTransportApple`, the default SMB2
  transport on Apple platforms. Not compiled on Linux.

---

The Apache-2.0 components (SwiftNIO, SwiftNIO Transport Services) are compatible
with App Store distribution and impose no dynamic-linking requirement of their
own; the dynamic-linking requirement above comes solely from libsmb2's LGPL-2.1
license.
