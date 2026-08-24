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

public import struct NIOCore.ByteBuffer

extension ByteBuffer {
    /// Read a single ``QPACKEncoderInstruction`` from this `ByteBuffer`.
    /// Moves the reader index to the end of the instruction.
    /// If a valid instruction can't be formed, returns nil and leaves the reader index as it was.
    /// - Returns: The instruction, or nil if it cannot be decoded.
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

    /// Encode a single ``QPACKEncoderInstruction`` into this `ByteBuffer`.
    /// - Parameters:
    ///   - instruction: The instruction to encode.
    ///   - preferHuffmanEncoding: Whether to use huffman coding for strings (where applicable and more efficient to do so).
    mutating func writeQPACKEncoderInstruction(
        _ instruction: QPACKEncoderInstruction,
        preferHuffmanEncoding: Bool
    ) {
        switch instruction {
        case .setDynamicTableCapacity(let capacity):
            self.writeQPACKPrefixedInteger(capacity, prefix: 5, prefixBits: 0x20)
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
            self.writeQPACKPrefixedInteger(relativeIndex, prefix: 6, prefixBits: prefixBits)
            self.writeQPACKEncodedString(value, preferHuffmanEncoding: preferHuffmanEncoding, prefix: 8)
        case .insertWithLiteralName(let name, let value):
            self.writeQPACKEncodedString(
                name,
                preferHuffmanEncoding: preferHuffmanEncoding,
                prefix: 6,
                prefixBits: 0x40
            )
            self.writeQPACKEncodedString(value, preferHuffmanEncoding: preferHuffmanEncoding, prefix: 8)
        case .duplicateEntry(let relativeIndex):
            self.writeQPACKPrefixedInteger(relativeIndex, prefix: 5, prefixBits: 0)
        }
    }

    /// Read a single ``QPACKDecoderInstruction`` from this `ByteBuffer`.
    /// Moves the reader index to the end of the instruction.
    /// If a valid instruction can't be formed, returns nil and leaves the reader index as it was.
    /// - Returns: The instruction, or nil if it cannot be decoded.
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
            return .streamCancellation(streamID: .init(rawValue: streamID))
        default:
            // Starts with 1
            // Remaining 7 bits are the streamID
            guard let streamID = try self.readQPACKPrefixedInteger(as: UInt64.self, withPrefix: 7) else {
                return nil
            }
            return .sectionAcknowledgement(streamID: .init(rawValue: streamID))
        }
    }

    /// Encode a single ``QPACKDecoderInstruction`` into this `ByteBuffer`.
    /// - Parameter instruction: The instruction to encode.
    mutating func writeQPACKDecoderInstruction(_ instruction: QPACKDecoderInstruction) {
        switch instruction {
        case .sectionAcknowledgement(let streamID):
            // Start with a 1, then a 7-bit prefix integer
            self.writeQPACKPrefixedInteger(streamID.rawValue, prefix: 7, prefixBits: 0x80)
        case .streamCancellation(let streamID):
            // Start with 01, then a 6-bit prefix integer
            self.writeQPACKPrefixedInteger(streamID.rawValue, prefix: 6, prefixBits: 0x40)
        case .insertCountIncrement(let increment):
            // Start with 00, then a 6-bit prefix integer
            self.writeQPACKPrefixedInteger(increment, prefix: 6, prefixBits: 0)
        }
    }
}

/// Encode qpack encoder instructions.
@_spi(PackageInternal)
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
        out.writeQPACKEncoderInstruction(data, preferHuffmanEncoding: self.preferHuffmanEncoding)
    }
}

/// Decode qpack encoder instructions.
@_spi(PackageInternal)
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
@_spi(PackageInternal)
public struct QPACKDecoderInstructionEncoder {
    @_spi(PackageInternal)
    public typealias OutboundIn = QPACKDecoderInstruction

    @_spi(PackageInternal)
    public init() {}

    @_spi(PackageInternal)
    public func encode(data: QPACKDecoderInstruction, out: inout ByteBuffer) {
        out.writeQPACKDecoderInstruction(data)
    }
}

/// Decode qpack decoder instructions.
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
