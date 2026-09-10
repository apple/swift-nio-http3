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
    /// Get the element of the static table at the specific index if it exists
    static func get(at index: Int) -> (HTTPField.Name, String)? {
        if staticHeaderTable.indices.contains(index) {
            return staticHeaderTable[index]
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
            for index in group.first where staticHeaderTable[index].1 == value {
                return (index: index, containsValue: true)
            }
            for index in group.second where staticHeaderTable[index].1 == value {
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
    @inline(__always)
    var isEmpty: Bool {
        self.firstStart == self.firstEnd
    }

    /// The first run of indices, which holds the lowest index carrying the name.
    @inline(__always)
    var first: Range<Int> {
        Int(self.firstStart)..<Int(self.firstEnd)
    }

    /// The second run of indices, empty for every name but two.
    @inline(__always)
    var second: Range<Int> {
        Int(self.secondStart)..<Int(self.secondEnd)
    }
}

extension UnsafeBufferPointer<UInt8> {
    /// Unchecked element access. Every index the lookup reads has been proven in range by the
    /// enclosing `switch` on `count`.
    @inline(__always)
    subscript(position position: Int) -> UInt8 {
        self.baseAddress.unsafelyUnwrapped[position]
    }
}
