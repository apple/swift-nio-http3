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
    @available(anyAppleOS 27, *)
    mutating func readQPACKEncodedString(withPrefix prefix: Int) throws(IntegerReadingError) -> String? {
        guard let result = try self.getQPACKEncodedString(at: self.readerIndex, withPrefix: prefix) else {
            return nil
        }
        self.moveReaderIndex(forwardBy: result.bytesRead)
        return result.value
    }

    /// Get one QPACK encoded string from this ByteBuffer without moving the reader index.
    @available(anyAppleOS 27, *)
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
}

extension QPACKEncodedLength {
    /// The largest number of bytes ``OutputRawSpan/appendQPACKEncodedString(_:preferHuffmanEncoding:prefix:prefixBits:)``
    /// appends for a string of `byteCount` bytes.
    static func maxString(byteCount: Int, prefix: Int) -> Int {
        // Huffman encoding is only used if it is shorter, so the string's own length is the most it takes. The
        // Huffman flag takes one bit of the prefix.
        Self.prefixedInteger(byteCount, prefix: prefix &- 1) &+ byteCount
    }
}

extension OutputRawSpan {
    /// Appends a string literal, encoded as in RFC 9204 § 4.1.2.
    ///
    /// - Parameters:
    ///   - bytes: The bytes of the string.
    ///   - preferHuffmanEncoding: If true, huffman encoding will be used only if it will save space. If false, huffman
    ///     encoding will not be used.
    ///   - prefix: The number of bits in the first byte left for the string, between 2 and 8.
    ///   - prefixBits: The bits to use in the first byte before the string begins.
    /// - Precondition: The span has room for ``QPACKEncodedLength/maxString(byteCount:prefix:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendQPACKEncodedString(
        _ bytes: Span<UInt8>,
        preferHuffmanEncoding: Bool,
        prefix: Int,
        prefixBits: UInt8 = 0
    ) {
        /// RFC 9204 4.1.2: The prefix size, N, can have a value between 2 and 8, inclusive. The remainder of the string literal is unmodified.
        precondition(prefix >= 2)
        precondition(prefix <= 8)

        if preferHuffmanEncoding {
            let huffmanEncodedByteLength = QPACKEncodedLength.huffman(of: bytes)
            // Huffman coding is usually, but not always, more space-efficient. It is optimised for regular ASCII range.
            if huffmanEncodedByteLength < bytes.count {
                let huffmanMask = UInt8(truncatingIfNeeded: 1 &<< (prefix - 1))
                // the prefix is now one bit less (one-bit huffman encoding flag)
                self.appendQPACKPrefixedInteger(
                    huffmanEncodedByteLength,
                    prefix: prefix - 1,
                    prefixBits: huffmanMask | prefixBits
                )
                self.appendHuffmanEncoded(bytes, encodedByteLength: huffmanEncodedByteLength)
                return
            }
        }

        // One bit is used for the Huffman flag (0)
        // So the prefix is reduced by one
        self.appendQPACKPrefixedInteger(bytes.count, prefix: prefix - 1, prefixBits: prefixBits)
        self.appendBytes(bytes)
    }

    /// Appends a string literal, encoded as in RFC 9204 § 4.1.2.
    ///
    /// - Precondition: The span has room for ``QPACKEncodedLength/maxString(byteCount:prefix:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendQPACKEncodedString(
        _ string: String,
        preferHuffmanEncoding: Bool,
        prefix: Int,
        prefixBits: UInt8 = 0
    ) {
        string.withContiguousUTF8 {
            self.appendQPACKEncodedString(
                $0,
                preferHuffmanEncoding: preferHuffmanEncoding,
                prefix: prefix,
                prefixBits: prefixBits
            )
        }
    }

    /// Appends `bytes` as they are.
    ///
    /// - Precondition: The span has room for `bytes.count` more bytes.
    mutating func appendBytes(_ bytes: Span<UInt8>) {
        precondition(self.freeCapacity >= bytes.count, "Not enough room for the bytes")
        bytes.withUnsafeBytes { source in
            self.withUnsafeMutableBytes { buffer, initializedCount in
                UnsafeMutableRawBufferPointer(rebasing: buffer[initializedCount...]).copyMemory(from: source)
                initializedCount &+= source.count
            }
        }
    }
}

extension String {
    /// Calls `body` with the UTF-8 bytes of this string.
    ///
    /// Strings which don't store contiguous UTF-8, such as a lazily bridged `NSString`, are copied into contiguous
    /// storage first.
    @available(anyAppleOS 27, *)
    func withContiguousUTF8<Result>(_ body: (Span<UInt8>) -> Result) -> Result {
        if let result = self.utf8.withContiguousStorageIfAvailable({ body($0.span) }) {
            return result
        }
        var copy = self
        return copy.withUTF8 { body($0.span) }
    }
}
