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

import NIOQUICHelpers

public import struct NIOCore.ByteBuffer

extension ByteBuffer {
    /// Read a single ``QPACKEncoderInstruction`` from this `ByteBuffer`.
    /// Moves the reader index to the end of the instruction.
    /// If a valid instruction can't be formed, returns nil and leaves the reader index as it was.
    /// - Returns: The instruction, or nil if it cannot be decoded.
    @available(anyAppleOS 27, *)
    mutating func readQPACKEncoderInstruction() throws(IntegerReadingError) -> QPACKEncoderInstruction? {
        guard let firstByte = self.peekInteger(as: UInt8.self) else {
            return nil
        }
        if firstByte & 0x80 == 0x80 {
            // First bit is 1. This is insertWithNameReference
            // The 2nd bit represents static table (1) or dynamic table (0)
            let table = QPACKReferenceTable.staticIfTrue(firstByte & 0x40 == 0x40)
            // Remaining 6 bits are start of the integer for the relative index
            guard
                let relativeIndex = try self.getQPACKPrefixedInteger(as: Int.self, at: self.readerIndex, withPrefix: 6)
            else {
                return nil
            }
            // Integers always end on a byte boundary
            guard
                let value = try self.getQPACKEncodedString(
                    at: self.readerIndex + relativeIndex.bytesRead,
                    withPrefix: 8
                )
            else {
                return nil
            }
            self.moveReaderIndex(forwardBy: relativeIndex.bytesRead + value.bytesRead)
            return .insertWithNameReference(table, relativeIndex: relativeIndex.value, value: value.value)
        } else if firstByte & 0x40 == 0x40 {
            // Second bit is 1, i.e we begin with a 01 pattern. This is insertWithLiteralName
            guard let name = try self.getQPACKEncodedString(at: self.readerIndex, withPrefix: 6) else {
                return nil
            }
            guard let value = try self.getQPACKEncodedString(at: self.readerIndex + name.bytesRead, withPrefix: 8)
            else {
                return nil
            }
            self.moveReaderIndex(forwardBy: name.bytesRead + value.bytesRead)
            return .insertWithLiteralName(name: name.value, value: value.value)
        } else if firstByte & 0x20 == 0x20 {
            // Third bit is 1, i.e. we begin with a 001 pattern. This is setDynamicTableCapacity
            guard let capacity = try self.readQPACKPrefixedInteger(as: Int.self, withPrefix: 5) else {
                return nil
            }
            return .setDynamicTableCapacity(capacity)
        } else {
            // First 3 bits are 000. This is duplicate
            guard let relativeIndex = try self.readQPACKPrefixedInteger(as: Int.self, withPrefix: 5) else {
                return nil
            }
            return .duplicateEntry(relativeIndex: relativeIndex)
        }
    }

    /// Read a single ``QPACKDecoderInstruction`` from this `ByteBuffer`.
    /// Moves the reader index to the end of the instruction.
    /// If a valid instruction can't be formed, returns nil and leaves the reader index as it was.
    /// - Returns: The instruction, or nil if it cannot be decoded.
    @available(anyAppleOS 27, *)
    mutating func readQPACKDecoderInstruction() throws(IntegerReadingError) -> QPACKDecoderInstruction? {
        guard let firstByte = self.getInteger(at: self.readerIndex, as: UInt8.self) else {
            return nil
        }
        let first2Bits = firstByte & 0xC0
        switch first2Bits {
        case 0:
            // Starts with 00
            // Remaining 6 bits are the increment
            guard let increment = try self.readQPACKPrefixedInteger(as: Int.self, withPrefix: 6) else {
                return nil
            }
            return .insertCountIncrement(increment: increment)
        case 0x40:
            // Starts with 01
            // Remaining 6 bits are the streamID
            guard let streamID = try self.readQPACKPrefixedInteger(as: UInt64.self, withPrefix: 6) else {
                return nil
            }
            // A prefixed integer can exceed the largest QUIC stream ID, which would trap in QUICStreamID.
            guard streamID <= QUICEncodableInteger.maxValue else {
                throw IntegerReadingError.unrepresentable
            }
            return .streamCancellation(streamID: .init(rawValue: streamID))
        default:
            // Starts with 1
            // Remaining 7 bits are the streamID
            guard let streamID = try self.readQPACKPrefixedInteger(as: UInt64.self, withPrefix: 7) else {
                return nil
            }
            guard streamID <= QUICEncodableInteger.maxValue else {
                throw IntegerReadingError.unrepresentable
            }
            return .sectionAcknowledgement(streamID: .init(rawValue: streamID))
        }
    }
}

extension OutputRawSpan {
    /// Appends a single ``QPACKEncoderInstruction``.
    /// - Parameters:
    ///   - instruction: The instruction to encode.
    ///   - preferHuffmanEncoding: Whether to use huffman coding for strings (where applicable and more efficient to do so).
    /// - Precondition: The span has room for ``QPACKEncodedLength/maxEncoderInstruction(_:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendQPACKEncoderInstruction(_ instruction: QPACKEncoderInstruction, preferHuffmanEncoding: Bool) {
        switch instruction {
        case .setDynamicTableCapacity(let capacity):
            self.appendQPACKPrefixedInteger(capacity, prefix: 5, prefixBits: 0x20)
        case .insertWithNameReference(let table, let relativeIndex, let value):
            // 1st bit is 1
            // 2nd bit represents static table (1) or dynamic table (0)
            let prefixBits: UInt8
            switch table {
            case .staticTable:
                prefixBits = 0xC0  // 11
            case .dynamicTable:
                prefixBits = 0x80  // 10
            }
            self.appendQPACKPrefixedInteger(relativeIndex, prefix: 6, prefixBits: prefixBits)
            self.appendQPACKEncodedString(value, preferHuffmanEncoding: preferHuffmanEncoding, prefix: 8)
        case .insertWithLiteralName(let name, let value):
            self.appendQPACKEncodedString(
                name,
                preferHuffmanEncoding: preferHuffmanEncoding,
                prefix: 6,
                prefixBits: 0x40
            )
            self.appendQPACKEncodedString(value, preferHuffmanEncoding: preferHuffmanEncoding, prefix: 8)
        case .duplicateEntry(let relativeIndex):
            self.appendQPACKPrefixedInteger(relativeIndex, prefix: 5, prefixBits: 0)
        }
    }

    /// Appends a single ``QPACKDecoderInstruction``.
    /// - Parameter instruction: The instruction to encode.
    /// - Precondition: The span has room for ``QPACKEncodedLength/decoderInstruction(_:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendQPACKDecoderInstruction(_ instruction: QPACKDecoderInstruction) {
        switch instruction {
        case .sectionAcknowledgement(let streamID):
            // Start with a 1, then a 7-bit prefix integer
            self.appendQPACKPrefixedInteger(streamID.rawValue, prefix: 7, prefixBits: 0x80)
        case .streamCancellation(let streamID):
            // Start with 01, then a 6-bit prefix integer
            self.appendQPACKPrefixedInteger(streamID.rawValue, prefix: 6, prefixBits: 0x40)
        case .insertCountIncrement(let increment):
            // Start with 00, then a 6-bit prefix integer
            self.appendQPACKPrefixedInteger(increment, prefix: 6, prefixBits: 0)
        }
    }
}

extension QPACKEncodedLength {
    /// The largest number of bytes ``OutputRawSpan/appendQPACKEncoderInstruction(_:preferHuffmanEncoding:)`` appends for
    /// `instruction`.
    @available(anyAppleOS 27, *)
    static func maxEncoderInstruction(_ instruction: QPACKEncoderInstruction) -> Int {
        switch instruction {
        case .setDynamicTableCapacity(let capacity):
            Self.prefixedInteger(capacity, prefix: 5)
        case .insertWithNameReference(_, let relativeIndex, let value):
            Self.prefixedInteger(relativeIndex, prefix: 6) &+ Self.maxString(byteCount: value.utf8.count, prefix: 8)
        case .insertWithLiteralName(let name, let value):
            Self.maxString(byteCount: name.utf8.count, prefix: 6)
                &+ Self.maxString(byteCount: value.utf8.count, prefix: 8)
        case .duplicateEntry(let relativeIndex):
            Self.prefixedInteger(relativeIndex, prefix: 5)
        }
    }

    /// The number of bytes ``OutputRawSpan/appendQPACKDecoderInstruction(_:)`` appends for `instruction`.
    @available(anyAppleOS 27, *)
    static func decoderInstruction(_ instruction: QPACKDecoderInstruction) -> Int {
        switch instruction {
        case .sectionAcknowledgement(let streamID):
            Self.prefixedInteger(streamID.rawValue, prefix: 7)
        case .streamCancellation(let streamID):
            Self.prefixedInteger(streamID.rawValue, prefix: 6)
        case .insertCountIncrement(let increment):
            Self.prefixedInteger(increment, prefix: 6)
        }
    }
}

/// Encode qpack encoder instructions.
@_spi(PackageInternal)
@available(anyAppleOS 27, *)
public struct QPACKEncoderInstructionEncoder {
    @_spi(PackageInternal)
    public typealias OutboundIn = QPACKEncoderInstruction

    private let preferHuffmanEncoding: Bool

    @_spi(PackageInternal)
    public init(preferHuffmanEncoding: Bool) {
        self.preferHuffmanEncoding = preferHuffmanEncoding
    }

    @_spi(PackageInternal)
    public func encode(data: QPACKEncoderInstruction, out: inout ByteBuffer) {
        out.writeWithOutputRawSpan(minimumWritableBytes: QPACKEncodedLength.maxEncoderInstruction(data)) {
            $0.appendQPACKEncoderInstruction(data, preferHuffmanEncoding: self.preferHuffmanEncoding)
        }
    }
}

/// Decode qpack encoder instructions.
@_spi(PackageInternal)
@available(anyAppleOS 27, *)
public struct QPACKEncoderInstructionDecoder {
    @_spi(PackageInternal)
    public init() {}

    @_spi(PackageInternal)
    public func decode(buffer: inout ByteBuffer) throws(IntegerReadingError) -> QPACKEncoderInstruction? {
        try buffer.readQPACKEncoderInstruction()
    }

    @_spi(PackageInternal)
    public func decodeLast(
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws(IntegerReadingError) -> QPACKEncoderInstruction? {
        try self.decode(buffer: &buffer)
    }
}

/// Encode qpack decoder instructions.
@available(anyAppleOS 27, *)
@_spi(PackageInternal)
public struct QPACKDecoderInstructionEncoder {
    @_spi(PackageInternal)
    public typealias OutboundIn = QPACKDecoderInstruction

    @_spi(PackageInternal)
    public init() {}

    @_spi(PackageInternal)
    public func encode(data: QPACKDecoderInstruction, out: inout ByteBuffer) {
        out.writeWithOutputRawSpan(minimumWritableBytes: QPACKEncodedLength.decoderInstruction(data)) {
            $0.appendQPACKDecoderInstruction(data)
        }
    }
}

/// Decode qpack decoder instructions.
@available(anyAppleOS 27, *)
@_spi(PackageInternal)
public struct QPACKDecoderInstructionDecoder {
    @_spi(PackageInternal)
    public init() {}

    @_spi(PackageInternal)
    public func decode(buffer: inout ByteBuffer) throws(IntegerReadingError) -> QPACKDecoderInstruction? {
        try buffer.readQPACKDecoderInstruction()
    }

    @_spi(PackageInternal)
    public func decodeLast(
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws(IntegerReadingError) -> QPACKDecoderInstruction? {
        try self.decode(buffer: &buffer)
    }
}
