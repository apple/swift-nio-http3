//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes

/// The QPACK static table as defined in RFC 9204 § 3.1.
///
/// The table itself, the entries regrouped by name and the name lookup live in
/// `StaticHeaderTable+Generated.swift`, which the `GenerateStaticHeaderTable` target produces from
/// the table in its `StaticTable.swift`. If the table changes, change it there and regenerate:
///
///     swift run GenerateStaticHeaderTable Sources/QPACK/Headers
enum StaticHeaderTable {
    /// This array represents all the static header table entries as defined in RFC 9204 § 3.1.
    ///
    /// The absolute index is the position, which is the array index. Note that the QPACK
    /// static table is indexed from 0, whereas the HPACK static table is indexed from 1.
    static let raw: [(name: HTTPField.Name, value: String)] = [
        (.init(parsed: ":authority")!, ""),  // 0
        (.init(parsed: ":path")!, "/"),  // 1
        (.init(parsed: "age")!, "0"),  // 2
        (.init(parsed: "content-disposition")!, ""),  // 3
        (.init(parsed: "content-length")!, "0"),  // 4
        (.init(parsed: "cookie")!, ""),  // 5
        (.init(parsed: "date")!, ""),  // 6
        (.init(parsed: "etag")!, ""),  // 7
        (.init(parsed: "if-modified-since")!, ""),  // 8
        (.init(parsed: "if-none-match")!, ""),  // 9
        (.init(parsed: "last-modified")!, ""),  // 10
        (.init(parsed: "link")!, ""),  // 11
        (.init(parsed: "location")!, ""),  // 12
        (.init(parsed: "referer")!, ""),  // 13
        (.init(parsed: "set-cookie")!, ""),  // 14
        (.init(parsed: ":method")!, "CONNECT"),  // 15
        (.init(parsed: ":method")!, "DELETE"),  // 16
        (.init(parsed: ":method")!, "GET"),  // 17
        (.init(parsed: ":method")!, "HEAD"),  // 18
        (.init(parsed: ":method")!, "OPTIONS"),  // 19
        (.init(parsed: ":method")!, "POST"),  // 20
        (.init(parsed: ":method")!, "PUT"),  // 21
        (.init(parsed: ":scheme")!, "http"),  // 22
        (.init(parsed: ":scheme")!, "https"),  // 23
        (.init(parsed: ":status")!, "103"),  // 24
        (.init(parsed: ":status")!, "200"),  // 25
        (.init(parsed: ":status")!, "304"),  // 26
        (.init(parsed: ":status")!, "404"),  // 27
        (.init(parsed: ":status")!, "503"),  // 28
        (.init(parsed: "accept")!, "*/*"),  // 29
        (.init(parsed: "accept")!, "application/dns-message"),  // 30
        (.init(parsed: "accept-encoding")!, "gzip, deflate, br"),  // 31
        (.init(parsed: "accept-ranges")!, "bytes"),  // 32
        (.init(parsed: "access-control-allow-headers")!, "cache-control"),  // 33
        (.init(parsed: "access-control-allow-headers")!, "content-type"),  // 34
        (.init(parsed: "access-control-allow-origin")!, "*"),  // 35
        (.init(parsed: "cache-control")!, "max-age=0"),  // 36
        (.init(parsed: "cache-control")!, "max-age=2592000"),  // 37
        (.init(parsed: "cache-control")!, "max-age=604800"),  // 38
        (.init(parsed: "cache-control")!, "no-cache"),  // 39
        (.init(parsed: "cache-control")!, "no-store"),  // 40
        (.init(parsed: "cache-control")!, "public, max-age=31536000"),  // 41
        (.init(parsed: "content-encoding")!, "br"),  // 42
        (.init(parsed: "content-encoding")!, "gzip"),  // 43
        (.init(parsed: "content-type")!, "application/dns-message"),  // 44
        (.init(parsed: "content-type")!, "application/javascript"),  // 45
        (.init(parsed: "content-type")!, "application/json"),  // 46
        (.init(parsed: "content-type")!, "application/x-www-form-urlencoded"),  // 47
        (.init(parsed: "content-type")!, "image/gif"),  // 48
        (.init(parsed: "content-type")!, "image/jpeg"),  // 49
        (.init(parsed: "content-type")!, "image/png"),  // 50
        (.init(parsed: "content-type")!, "text/css"),  // 51
        (.init(parsed: "content-type")!, "text/html; charset=utf-8"),  // 52
        (.init(parsed: "content-type")!, "text/plain"),  // 53
        (.init(parsed: "content-type")!, "text/plain;charset=utf-8"),  // 54
        (.init(parsed: "range")!, "bytes=0-"),  // 55
        (.init(parsed: "strict-transport-security")!, "max-age=31536000"),  // 56
        (.init(parsed: "strict-transport-security")!, "max-age=31536000; includesubdomains"),  // 57
        (.init(parsed: "strict-transport-security")!, "max-age=31536000; includesubdomains; preload"),  // 58
        (.init(parsed: "vary")!, "accept-encoding"),  // 59
        (.init(parsed: "vary")!, "origin"),  // 60
        (.init(parsed: "x-content-type-options")!, "nosniff"),  // 61
        (.init(parsed: "x-xss-protection")!, "1; mode=block"),  // 62
        (.init(parsed: ":status")!, "100"),  // 63
        (.init(parsed: ":status")!, "204"),  // 64
        (.init(parsed: ":status")!, "206"),  // 65
        (.init(parsed: ":status")!, "302"),  // 66
        (.init(parsed: ":status")!, "400"),  // 67
        (.init(parsed: ":status")!, "403"),  // 68
        (.init(parsed: ":status")!, "421"),  // 69
        (.init(parsed: ":status")!, "425"),  // 70
        (.init(parsed: ":status")!, "500"),  // 71
        (.init(parsed: "accept-language")!, ""),  // 72
        (.init(parsed: "access-control-allow-credentials")!, "FALSE"),  // 73
        (.init(parsed: "access-control-allow-credentials")!, "TRUE"),  // 74
        (.init(parsed: "access-control-allow-headers")!, "*"),  // 75
        (.init(parsed: "access-control-allow-methods")!, "get"),  // 76
        (.init(parsed: "access-control-allow-methods")!, "get, post, options"),  // 77
        (.init(parsed: "access-control-allow-methods")!, "options"),  // 78
        (.init(parsed: "access-control-expose-headers")!, "content-length"),  // 79
        (.init(parsed: "access-control-request-headers")!, "content-type"),  // 80
        (.init(parsed: "access-control-request-method")!, "get"),  // 81
        (.init(parsed: "access-control-request-method")!, "post"),  // 82
        (.init(parsed: "alt-svc")!, "clear"),  // 83
        (.init(parsed: "authorization")!, ""),  // 84
        (.init(parsed: "content-security-policy")!, "script-src 'none'; object-src 'none'; base-uri 'none'"),  // 85
        (.init(parsed: "early-data")!, "1"),  // 86
        (.init(parsed: "expect-ct")!, ""),  // 87
        (.init(parsed: "forwarded")!, ""),  // 88
        (.init(parsed: "if-range")!, ""),  // 89
        (.init(parsed: "origin")!, ""),  // 90
        (.init(parsed: "purpose")!, "prefetch"),  // 91
        (.init(parsed: "server")!, ""),  // 92
        (.init(parsed: "timing-allow-origin")!, "*"),  // 93
        (.init(parsed: "upgrade-insecure-requests")!, "1"),  // 94
        (.init(parsed: "user-agent")!, ""),  // 95
        (.init(parsed: "x-forwarded-for")!, ""),  // 96
        (.init(parsed: "x-frame-options")!, "deny"),  // 97
        (.init(parsed: "x-frame-options")!, "sameorigin"),  // 98
    ]

    /// Get the element of the static table at the specific index if it exists
    static func get(at index: Int) -> (name: HTTPField.Name, value: String)? {
        if Self.raw.indices.contains(index) {
            return Self.raw[index]
        } else {
            return nil
        }
    }

    /// Searches the table for a matching header, optionally with a particular value. If
    /// a match is found, returns the index of the item and an indication whether it contained
    /// the matching value as well.
    ///
    /// Invariants: If `value` is `nil`, result `containsValue` is `false`.
    ///
    /// - Parameters:
    ///   - name: The name of the header for which to search.
    ///   - value: Optional value for the header to find.
    /// - Returns: A tuple containing the matching index and, if a value was specified as a
    ///            parameter, an indication whether that value was also found. Returns `nil`
    ///            if no matching header name could be located.
    static func find(name: HTTPField.Name, value: String?) -> (index: Int, containsValue: Bool)? {
        let group = Self.entryGroup(for: name)
        guard !group.isEmpty else {
            return nil
        }

        if let value {
            for index in group.first where Self.raw[index].value == value {
                return (index: index, containsValue: true)
            }
            for index in group.second where Self.raw[index].value == value {
                return (index: index, containsValue: true)
            }
        }

        // No value (or no matching value), return the first index carrying the name.
        return (index: group.first.lowerBound, containsValue: false)
    }

    /// Resolves `name` to the static table indices carrying that name, or an empty group if the
    /// static table doesn't carry it.
    ///
    /// See `entryGroup(canonicalName:utf8:)`, which is generated.
    ///
    /// The name is handed to the lookup as well as its bytes because the lookup confirms a
    /// candidate with a whole-string comparison, which is one `memcmp` rather than a
    /// byte-at-a-time loop.
    static func entryGroup(for name: HTTPField.Name) -> StaticEntryGroup {
        let canonicalName = name.canonicalName
        let result = canonicalName.utf8.withContiguousStorageIfAvailable {
            Self.entryGroup(canonicalName: canonicalName, utf8: $0)
        }
        if let result {
            return result
        }
        // Non-contiguous UTF-8 (a lazily bridged `NSString`). Copy into contiguous storage.
        var copy = canonicalName
        return copy.withUTF8 { Self.entryGroup(canonicalName: canonicalName, utf8: $0) }
    }
}

/// The static table indices carrying one field name.
///
/// The entries sharing a name are contiguous in the static table, except for `:status` and
/// `access-control-allow-headers`, which RFC 9204 continues past index 62 — so a name needs at
/// most two runs. Holding them as `UInt8` bounds (the table has 99 entries) keeps the whole group
/// in a register.
struct StaticEntryGroup {
    private let firstStart: UInt8
    private let firstEnd: UInt8
    private let secondStart: UInt8
    private let secondEnd: UInt8

    /// The group of a name the static table doesn't carry.
    static let none = StaticEntryGroup(0, 0)

    init(_ firstStart: UInt8, _ firstEnd: UInt8, _ secondStart: UInt8 = 0, _ secondEnd: UInt8 = 0) {
        self.firstStart = firstStart
        self.firstEnd = firstEnd
        self.secondStart = secondStart
        self.secondEnd = secondEnd
    }

    /// Whether the static table carries the name at all.
    var isEmpty: Bool {
        self.firstStart == self.firstEnd
    }

    /// The first run of indices, which holds the lowest index carrying the name.
    var first: Range<Int> {
        Int(self.firstStart)..<Int(self.firstEnd)
    }

    /// The second run of indices, empty for every name but two.
    var second: Range<Int> {
        Int(self.secondStart)..<Int(self.secondEnd)
    }
}

extension UnsafeBufferPointer<UInt8> {
    /// Unchecked element access. Every index the lookup reads has been proven in range by the
    /// enclosing `switch` on `count`.
    subscript(position position: Int) -> UInt8 {
        self.baseAddress.unsafelyUnwrapped[position]
    }
}
