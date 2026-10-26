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

public import HTTPTypes

/// Can encode field sections but only statically (can't use dynamic table and can't send instructions).
@available(anyAppleOS 27, *)
@_spi(PackageInternal)
public struct StaticQPACKEncoder {
    @_spi(PackageInternal)
    public init() {}

    @_spi(PackageInternal)
    public func encode(headers: [HTTPField]) -> FieldSection {
        let base = 0  // base 0 is the cheapest way when no dynamic entries
        var lines = [FieldLine]()
        lines.reserveCapacity(headers.count)
        for header in headers {
            let requireLiteralRepresentation =
                switch header.indexingStrategy {
                case .prefer, .automatic, .avoid: false
                case .disallow: true
                default: false
                }
            lines.append(
                self.encodeSingleHeader(
                    header,
                    requireLiteralRepresentation: requireLiteralRepresentation
                ).asFieldLine(base: base)
            )
        }
        let prefix = FieldSectionPrefix(requiredInsertCount: 0, base: base)
        let encodedPrefix = prefix.encode(maxCapacity: 0)

        return .init(prefix: encodedPrefix, lines: lines)
    }

    /// - Parameters
    ///     - header: The header to be encoded.
    ///     - requireLiteralRepresentation: If true, a flag will be set requiring intermediates to keep this header as a literal.
    /// - Returns: The encoded header.
    func encodeSingleHeader(
        _ header: HTTPField,
        requireLiteralRepresentation: Bool
    ) -> HeaderRepresentation {
        let staticTableEntry = StaticHeaderTable.find(name: header.name, value: header.value)
        if let staticTableEntry, staticTableEntry.containsValue {
            // Exact match in static table
            return .staticTableReference(index: staticTableEntry.index)
        } else if let staticTableEntry {
            // Partial match in static table
            return .staticTableNameReference(
                requireLiteralRepresentation: requireLiteralRepresentation,
                index: staticTableEntry.index,
                value: header.value
            )
        } else {
            // We already checked static table, and there's no dynamic table, so it's a literal
            return .literal(
                requireLiteralRepresentation: requireLiteralRepresentation,
                name: header.name,
                value: header.value
            )
        }
    }
}
