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

/// A bit like ``FieldLine`` but without caring about wire representation.
private enum HeaderRepresentation {
    case literal(requireLiteralRepresentation: Bool, name: HTTPField.Name, value: String)
    case staticTableReference(index: Int)
    case staticTableNameReference(requireLiteralRepresentation: Bool, index: Int, value: String)

    var asFieldLine: FieldLine {
        switch self {
        case .literal(let requireLiteralRepresentation, let name, let value):
            return .literal(
                requireLiteralRepresentation: requireLiteralRepresentation,
                name: name.canonicalName,
                value: value
            )
        case .staticTableReference(let index):
            return .indexed(.staticTable, index: index)
        case .staticTableNameReference(let requireLiteralRepresentation, let index, let value):
            return .literalWithNameReference(
                requireLiteralRepresentation: requireLiteralRepresentation,
                table: .staticTable,
                index: index,
                value: value
            )
        }
    }
}

/// Encodes field sections against the QPACK static table.
///
/// This implementation does not use the dynamic table, so it never needs to emit encoder instructions and
/// every field section it produces has a Required Insert Count of zero.
@_spi(PackageInternal)
public struct QPACKEncoder: Sendable {
    @_spi(PackageInternal)
    public init() {}

    @_spi(PackageInternal)
    public func encode(headers: [HTTPField]) -> FieldSection {
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
                ).asFieldLine
            )
        }

        return .init(prefix: .staticOnly, lines: lines)
    }

    /// - Parameters
    ///     - header: The header to be encoded.
    ///     - requireLiteralRepresentation: If true, a flag will be set requiring intermediates to keep this header as a literal.
    /// - Returns: The encoded header.
    private func encodeSingleHeader(
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
            // There's no dynamic table, so anything the static table doesn't cover is a literal
            return .literal(
                requireLiteralRepresentation: requireLiteralRepresentation,
                name: header.name,
                value: header.value
            )
        }
    }
}
