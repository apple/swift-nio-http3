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

import struct NIOCore.ByteBuffer

extension ByteBuffer {
    /// Read one QPACK encoded string from this ByteBuffer.
    /// Will move the reader index to the end of the string.
    /// If a qpack encoded string cannot be read, nil will be returned and the index will be left where it was.
    mutating func readQPACKEncodedString(withPrefix prefix: Int) throws(IntegerReadingError) -> String? {
        guard let result = try self.getQPACKEncodedString(at: self.readerIndex, withPrefix: prefix) else {
            return nil
        }
        self.moveReaderIndex(forwardBy: result.bytesRead)
        return result.value
    }

    /// Get one QPACK encoded string from this ByteBuffer without moving the reader index.
    func getQPACKEncodedString(
        at: Int,
        withPrefix prefix: Int
    ) throws(IntegerReadingError) -> Decoded<String>? {
        /// RFC 9204 4.1.2: The prefix size, N, can have a value between 2 and 8, inclusive. The remainder of the string literal is unmodified.
        precondition(prefix >= 2)
        precondition(prefix <= 8)
        // peek to read the encoding bit
        guard let initialByte: UInt8 = self.getInteger(at: at) else {
            return nil
        }
        // We are using huffman encoding if the first bit after the prefix is 1
        // E.g. is prefix is 4, then the 5th bit represents huffman coding
        // so in that case we would & 0b00001000
        let huffmanMask = UInt8(truncatingIfNeeded: 1 &<< (prefix - 1))
        let huffmanEncoded = initialByte & huffmanMask == huffmanMask

        // read the length; the prefix is now one bit less (one-bit encoding flag above)
        guard let lengthInt = try self.getQPACKPrefixedInteger(as: Int.self, at: at, withPrefix: prefix - 1) else {
            return nil
        }

        if huffmanEncoded {
            guard
                let string = self.getHuffmanEncodedString(
                    at: at + lengthInt.bytesRead,
                    length: lengthInt.value
                )
            else { return nil }
            return Decoded<String>(value: string, bytesRead: lengthInt.bytesRead + lengthInt.value)
        } else {
            guard let string = self.getString(at: at + lengthInt.bytesRead, length: lengthInt.value) else {
                return nil
            }
            return Decoded<String>(value: string, bytesRead: lengthInt.bytesRead + lengthInt.value)
        }
    }

    /// Write a string to this buffer, encoded for QPACK.
    /// The prefix must be between 2 and 8
    /// Parameters:
    /// - preferHuffmanEncoding: If true, huffman encoding will be used only if it will save space. If false, huffman encoding will not be used.
    /// - prefix: The number of bits in the first byte leave before starting the string
    /// - prefixBits: The bits to use in the first byte before the string begins.
    @discardableResult
    mutating func writeQPACKEncodedString(
        _ string: String,
        preferHuffmanEncoding: Bool,
        prefix: Int,
        prefixBits: UInt8 = 0
    ) -> Int {
        /// RFC 9204 4.1.2: The prefix size, N, can have a value between 2 and 8, inclusive. The remainder of the string literal is unmodified.
        precondition(prefix >= 2)
        precondition(prefix <= 8)
        let start = self.writerIndex
        let utf8 = string.utf8

        enum Encoding {
            case huffman(encodedByteLength: Int)
            case raw
        }

        // Using an enum to capture whether or not to use huffman AND the byte length means we avoid calculating the byte length again later
        let encoding: Encoding
        if preferHuffmanEncoding {
            let huffmanEncodedByteLength = Self.huffmanEncodedByteLength(of: utf8)
            let unencodedByteLength = utf8.count
            // Huffman coding is usually, but not always, more space-efficient. It is optimised for regular ASCII range.
            if huffmanEncodedByteLength < unencodedByteLength {
                encoding = .huffman(encodedByteLength: huffmanEncodedByteLength)
            } else {
                encoding = .raw
            }
        } else {
            encoding = .raw
        }

        // encode the value
        switch encoding {
        case .huffman(let encodedByteLength):
            let huffmanMask = UInt8(truncatingIfNeeded: 1 &<< (prefix - 1))
            // the prefix is now one bit less (one-bit huffman encoding flag)
            self.writeQPACKPrefixedInteger(
                encodedByteLength,
                prefix: prefix - 1,
                prefixBits: huffmanMask | prefixBits
            )
            self.writeHuffmanEncoded(bytes: utf8)
        case .raw:
            // One bit is used for the Huffman flag (0)
            // So the prefix is reduced by one
            self.writeQPACKPrefixedInteger(utf8.count, prefix: prefix - 1, prefixBits: prefixBits)
            self.writeBytes(utf8)
        }
        return self.writerIndex &- start
    }
}
