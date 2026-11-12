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

    /// The max number of bytes ``encode(fields:into:preferHuffmanEncoding:)-(HTTPFields,_,_)`` appends for `fields`.
    public func maxEncodedLength(of fields: HTTPFields) -> Int {
        Self.prefixLength &+ Self.maxEncodedLengthWithoutPrefix(of: fields)
    }

    /// Encodes `fields` into a field section, and appends it to `output`.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)-(HTTPFields)`` more bytes.
    public func encode(fields: HTTPFields, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        output.appendFieldSectionPrefix(Self.staticPrefix)
        self.append(fields, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    /// The max number of bytes ``encode(fields:into:preferHuffmanEncoding:)-([HTTPField],_,_)`` appends for `fields`.
    public func maxEncodedLength(of fields: [HTTPField]) -> Int {
        Self.prefixLength &+ Self.maxEncodedLengthWithoutPrefix(of: fields)
    }

    /// Encodes `fields` into a field section, and appends it to `output`.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)-([HTTPField])`` more bytes.
    public func encode(fields: [HTTPField], into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        output.appendFieldSectionPrefix(Self.staticPrefix)
        self.append(fields, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    /// The prefix of every field section this encoder produces: it references no dynamic table entries and is therefore always
    /// the same.
    private static var staticPrefix: EncodedFieldSectionPrefix {
        FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 0)
    }

    /// The max number of bytes ``encode(request:into:preferHuffmanEncoding:)`` appends for `request`.
    public func maxEncodedLength(of request: HTTPRequest) -> Int {
        Self.prefixLength
            &+ Self.maxEncodedLengthWithoutPrefix(of: RequestPseudoHeaderFieldSequence(request.pseudoHeaderFields))
            &+ Self.maxEncodedLengthWithoutPrefix(of: request.headerFields)
    }

    /// Encodes `request` into a field section, its pseudo header fields first, and appends it to `output`.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)-(HTTPRequest)`` more bytes.
    public func encode(request: HTTPRequest, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        output.appendFieldSectionPrefix(Self.staticPrefix)
        // One loop over the pseudo header fields, rather than one call per field, lets the field line encoding be
        // inlined. The header fields keep a loop of their own, as walking them through the sequence costs more.
        self.append(
            RequestPseudoHeaderFieldSequence(request.pseudoHeaderFields),
            into: &output,
            preferHuffmanEncoding: preferHuffmanEncoding
        )
        self.append(request.headerFields, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    /// The max number of bytes ``encode(response:into:preferHuffmanEncoding:)`` appends for `response`.
    public func maxEncodedLength(of response: HTTPResponse) -> Int {
        Self.prefixLength
            &+ Self.maxEncodedLengthOfField(response.pseudoHeaderFields.status)
            &+ Self.maxEncodedLengthWithoutPrefix(of: response.headerFields)
    }

    /// Encodes `response` into a field section, its pseudo header field first, and appends it to `output`.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)-(HTTPResponse)`` more bytes.
    public func encode(response: HTTPResponse, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        output.appendFieldSectionPrefix(Self.staticPrefix)
        self.append(response.pseudoHeaderFields.status, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        self.append(response.headerFields, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    private static var prefixLength: Int {
        QPACKEncodedLength.fieldSectionPrefix(Self.staticPrefix)
    }

    private static func maxEncodedLengthOfField(_ field: HTTPField) -> Int {
        QPACKEncodedLength.maxFieldLine(field, indexLimit: StaticHeaderTable.raw.count)
    }

    private static func maxEncodedLengthWithoutPrefix(of fields: some Sequence<HTTPField>) -> Int {
        QPACKEncodedLength.maxFieldLines(fields, indexLimit: StaticHeaderTable.raw.count)
    }

    private func append(_ field: HTTPField, into output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        let fieldLine = self.fieldLine(for: field)
        output.appendFieldLine(fieldLine, preferHuffmanEncoding: preferHuffmanEncoding)
    }

    private func append(
        _ fields: some Sequence<HTTPField>,
        into output: inout OutputRawSpan,
        preferHuffmanEncoding: Bool
    ) {
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

/// The pseudo header fields of a request, in the order they are encoded.
private struct RequestPseudoHeaderFieldSequence: Sequence, IteratorProtocol {
    private enum Position {
        case method
        case scheme
        case authority
        case path
        case extendedConnectProtocol
        case done
    }

    private let fields: HTTPRequest.PseudoHeaderFields
    private var position: Position = .method

    init(_ fields: HTTPRequest.PseudoHeaderFields) {
        self.fields = fields
    }

    mutating func next() -> HTTPField? {
        switch self.position {
        case .method:
            self.position = .scheme
            return self.fields.method
        case .scheme:
            self.position = .authority
            if let scheme = self.fields.scheme {
                return scheme
            }
            fallthrough
        case .authority:
            self.position = .path
            if let authority = self.fields.authority {
                return authority
            }
            fallthrough
        case .path:
            self.position = .extendedConnectProtocol
            if let path = self.fields.path {
                return path
            }
            fallthrough
        case .extendedConnectProtocol:
            self.position = .done
            return self.fields.extendedConnectProtocol
        case .done:
            return nil
        }
    }
}

extension QPACKEncodedLength {
    /// The max number of bytes the field lines encoding `headers` take, if every table index the encoder may
    /// reference is below `indexLimit`.
    static func maxFieldLines(_ headers: some Sequence<HTTPField>, indexLimit: Int) -> Int {
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
