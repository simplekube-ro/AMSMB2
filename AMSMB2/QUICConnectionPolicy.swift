//
//  QUICConnectionPolicy.swift
//  AMSMB2
//
//  Created by Amir Abbas on 24/07/2026.
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import Foundation
#if canImport(Glibc)
import Glibc
#endif

extension SMB2Client {
    // MARK: - Numeric-host classification (design D4)

    /// Reports whether `host` is a numeric IPv4/IPv6 address (in any form the platform resolver
    /// recognizes without DNS) rather than a name — the basis for SMB-over-QUIC's
    /// "non-numeric hostnames only" policy.
    ///
    /// The primary classifier is `getaddrinfo(host, nil, &hints, …)` with
    /// `hints.ai_flags = AI_NUMERICHOST` (`AF_UNSPEC`, `SOCK_STREAM`): a `0` return means the
    /// resolver accepts the string as a numeric address with no lookup, which is *expected* to
    /// catch more than canonical literals — legacy IPv4 short/decimal/hex/octal forms,
    /// IPv4-mapped IPv6, and scoped IPv6. Because the required rejection table is acceptance
    /// criteria rather than a platform observation (design D4), a fail-closed deterministic
    /// supplement covers any legacy or scoped form a given platform's `getaddrinfo` might miss;
    /// the union is fail-closed and never weakens the table.
    ///
    /// An empty host is not a usable hostname and is classified as numeric (rejected) so the
    /// single caller-side check covers both the numeric and empty cases (design D4).
    static func isNumericHost(_ host: String) -> Bool {
        if host.isEmpty {
            return true
        }

        // Primary classifier: the platform resolver's own numeric determination (no DNS).
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
// `SOCK_STREAM` imports as a plain `Int32` on Darwin but as the `__socket_type` enum on
// Glibc — normalize to `Int32` so the classifier compiles on both (Linux gotcha).
#if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
#else
        hints.ai_socktype = SOCK_STREAM
#endif
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &hints, &info) == 0 {
            freeaddrinfo(info)
            return true
        }

        // Deterministic supplement (design D4 — fail-closed union). Kept unconditionally so the
        // required rejection table holds even on a platform whose `getaddrinfo(AI_NUMERICHOST)`
        // declines a legacy or scoped form. It only ever *adds* rejections; it never accepts a
        // hostname (`inet_aton`/`inet_pton` reject names).

        // Scoped IPv6 (`fe80::1%en0`): classify the address portion ahead of the zone id.
        let addressPart: Substring
        if let percent = host.firstIndex(of: "%") {
            addressPart = host[host.startIndex..<percent]
        } else {
            addressPart = host[...]
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, String(addressPart), &v6) == 1 {
            return true
        }

        // Legacy IPv4 grammar: `inet_aton` accepts exactly the short/decimal-integer/hex/octal
        // forms (`127.1`, `2130706433`, `0x7f000001`, `0177.0.0.1`) and rejects hostnames.
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            return true
        }

        return false
    }

    // MARK: - Connect-timeout normalization (design D10)

    /// Validates and normalizes a QUIC connect deadline (in seconds), sourced from
    /// `SMBQUICConfiguration.connectTimeout` — never from `SMB2Client.timeout`, and independent
    /// of it (design D10). The QUIC connect deadline is dedicated, finite, and always armed; it
    /// cannot be disabled.
    ///
    /// - `NaN`, `±infinity`, `0`, and negative values throw `POSIXError(.EINVAL)` — a non-finite
    ///   or non-positive deadline is a configuration error, never "disabled".
    /// - Values greater than 3600 s are clamped to 3600 s (bounds a typo'd deadline and keeps
    ///   the timer arithmetic trivially safe); `3600` itself passes unclamped.
    /// - All other finite positive values (including sub-second) pass through unchanged.
    static func normalizedQUICConnectTimeout(_ value: TimeInterval) throws -> TimeInterval {
        guard value.isFinite, value > 0 else {
            throw POSIXError(
                .EINVAL,
                description: "QUIC connectTimeout must be a finite, positive number of seconds"
            )
        }
        return min(value, 3600)
    }
}
