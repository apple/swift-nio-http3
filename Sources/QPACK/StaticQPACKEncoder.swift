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
public struct StaticQPACKEncoder {
    public init() {}

    /// The largest number of bytes ``encode(headers:into:preferHuffmanEncoding:)`` appends for `fields`.
    public func maxEncodedLength(of fields: [HTTPField]) -> Int {
        Self.prefixLength &+ QPACKEncodedLength.maxFieldLines(fields, indexLimit: StaticHeaderTable.raw.count)
    }

    /// Encodes `headers` into a field section, and appends it to `output`.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)-([HTTPField])`` more bytes.
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

    /// The largest number of bytes ``encode(request:into:preferHuffmanEncoding:)`` appends for `request`.
    public func maxEncodedLength(of request: HTTPRequest) -> Int {
        let pseudo = request.pseudoHeaderFields
        var length = Self.prefixLength &+ Self.maxEncodedLength(of: pseudo.method)
        if let scheme = pseudo.scheme {
            length &+= Self.maxEncodedLength(of: scheme)
        }
        if let authority = pseudo.authority {
            length &+= Self.maxEncodedLength(of: authority)
        }
        if let path = pseudo.path {
            length &+= Self.maxEncodedLength(of: path)
        }
        if let extendedConnectProtocol = pseudo.extendedConnectProtocol {
            length &+= Self.maxEncodedLength(of: extendedConnectProtocol)
        }
        return length &+ Self.maxEncodedLength(of: request.headerFields)
    }

    /// Encodes `request` into a field section, its pseudo header fields first, and appends it to `output`.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)-(HTTPRequest)`` more bytes.
    public func encode(request: HTTPRequest, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        let pseudo = request.pseudoHeaderFields
        output.appendFieldSectionPrefix(Self.staticPrefix)
        self.append(pseudo.method, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        if let scheme = pseudo.scheme {
            self.append(scheme, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        }
        if let authority = pseudo.authority {
            self.append(authority, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        }
        if let path = pseudo.path {
            self.append(path, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        }
        if let extendedConnectProtocol = pseudo.extendedConnectProtocol {
            self.append(extendedConnectProtocol, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        }
        self.append(request.headerFields, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    /// The largest number of bytes ``encode(response:into:preferHuffmanEncoding:)`` appends for `response`.
    public func maxEncodedLength(of response: HTTPResponse) -> Int {
        Self.prefixLength
            &+ Self.maxEncodedLength(of: response.pseudoHeaderFields.status)
            &+ Self.maxEncodedLength(of: response.headerFields)
    }

    /// Encodes `response` into a field section, its pseudo header field first, and appends it to `output`.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)-(HTTPResponse)`` more bytes.
    public func encode(response: HTTPResponse, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        output.appendFieldSectionPrefix(Self.staticPrefix)
        self.append(response.pseudoHeaderFields.status, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        self.append(response.headerFields, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    /// The largest number of bytes ``encode(fields:into:preferHuffmanEncoding:)`` appends for `fields`.
    public func maxEncodedLength(of fields: HTTPFields) -> Int {
        Self.prefixLength &+ Self.maxEncodedLength(of: fields)
    }

    /// Encodes `fields` into a field section, and appends it to `output`.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)-(HTTPFields)`` more bytes.
    public func encode(fields: HTTPFields, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        output.appendFieldSectionPrefix(Self.staticPrefix)
        self.append(fields, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    private static var prefixLength: Int {
        QPACKEncodedLength.fieldSectionPrefix(Self.staticPrefix)
    }

    private static func maxEncodedLength(of field: HTTPField) -> Int {
        QPACKEncodedLength.maxFieldLine(field, indexLimit: StaticHeaderTable.raw.count)
    }

    private static func maxEncodedLength(of fields: HTTPFields) -> Int {
        var length = 0
        for field in fields {
            length &+= Self.maxEncodedLength(of: field)
        }
        return length
    }

    private func append(_ field: HTTPField, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        let fieldLine = self.fieldLine(for: field)
        output.appendFieldLine(fieldLine, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    private func append(_ fields: HTTPFields, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        for field in fields {
            self.append(field, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        }
    }

    /// Encodes a single field.
    func fieldLine(for header: HTTPField) -> FieldLine {
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
    /// The max number of bytes the field lines encoding `headers` take, if every table index the encoder may
    /// reference is below `indexLimit`.
    static func maxFieldLines(_ headers: [HTTPField], indexLimit: Int) -> Int {
        var length = 0
        for header in headers {
            length &+= Self.maxFieldLine(header, indexLimit: indexLimit)
        }
        return length
    }

    /// The max number of bytes the field line encoding `header` takes, if every table index the encoder may
    /// reference is below `indexLimit`.
    static func maxFieldLine(_ header: HTTPField, indexLimit: Int) -> Int {
        // The smallest index prefix is 3 bits (RFC 9204 § 4.5.5). A name is an index or a string literal; a value, if
        // present, is a string literal.
        let maxIndex = Self.prefixedInteger(indexLimit, prefix: 3)
        let maxName = Self.maxString(byteCount: header.name.canonicalName.utf8.count, prefix: 4)
        return max(maxName, maxIndex) &+ Self.maxString(byteCount: header.value.utf8.count, prefix: 8)
    }
}
