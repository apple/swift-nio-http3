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
        var lines = [FieldLine]()
        lines.reserveCapacity(headers.count)
        for header in headers {
            lines.append(self.fieldLine(for: header))
        }
        return .init(prefix: Self.staticPrefix, lines: lines)
    }

    /// The largest number of bytes ``encode(headers:into:preferHuffmanEncoding:)`` appends for `headers`.
    @_spi(PackageInternal)
    public func maxEncodedLength(of headers: [HTTPField]) -> Int {
        QPACKEncodedLength.fieldSectionPrefix(Self.staticPrefix)
            &+ QPACKEncodedLength.maxFieldLines(headers, indexLimit: StaticHeaderTable.raw.count)
    }

    /// Encodes `headers` into a field section, and appends it to `output`. No intermediate ``FieldSection`` is built.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)`` more bytes.
    @_spi(PackageInternal)
    public func encode(headers: [HTTPField], into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        output.appendFieldSectionPrefix(Self.staticPrefix)
        for header in headers {
            output.appendFieldLine(self.fieldLine(for: header), preferHuffmanEncoding: preferHuffmanEncoding)
        }
    }

    /// The prefix of every field section this encoder produces: it references no dynamic table entries and is therefore always
    /// the same.
    private static var staticPrefix: EncodedFieldSectionPrefix {
        FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 0)
    }

    /// Encodes a single field.
    private func fieldLine(for header: HTTPField) -> FieldLine {
        let requireLiteralRepresentation: Bool
        switch header.indexingStrategy {
        case .prefer, .automatic, .avoid:
            requireLiteralRepresentation = false
        case .disallow:
            requireLiteralRepresentation = true
        default:
            requireLiteralRepresentation = false
        }

        return self.encodeSingleHeader(header, requireLiteralRepresentation: requireLiteralRepresentation)
            .asFieldLine(base: 0)
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

extension QPACKEncodedLength {
    /// The largest number of bytes the field lines encoding `headers` take, if every table index the encoder may
    /// reference is below `indexLimit`.
    static func maxFieldLines(_ headers: [HTTPField], indexLimit: Int) -> Int {
        // The smallest index prefix is 3 bits (RFC 9204 § 4.5.5). A name is an index or a string literal; a value, if
        // present, is a string literal.
        let maxIndex = Self.prefixedInteger(indexLimit, prefix: 3)
        var length = 0
        for header in headers {
            let maxName = Self.maxString(byteCount: header.name.canonicalName.utf8.count, prefix: 4)
            length &+= max(maxName, maxIndex) &+ Self.maxString(byteCount: header.value.utf8.count, prefix: 8)
        }
        return length
    }
}
