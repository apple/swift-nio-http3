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

/// Reads QUIC variable-length integers (RFC 9000 § 16) straight out of the bytes the stream hands over.
@available(anyAppleOS 27, *)
enum QUICVarint {
    /// The outcome of reading an integer.
    enum ReadResult {
        /// The integer and the number of bytes it took.
        case value(UInt64, length: Int)
        /// `bytes` ends before the integer does: at least `needed` bytes are needed, counted from `offset`.
        case incomplete(needed: Int)
    }

    /// Reads the integer which starts `offset` bytes into `bytes`.
    static func read(_ bytes: borrowing RawSpan, at offset: Int) -> ReadResult {
        let available = bytes.byteCount &- offset
        guard available > 0 else {
            return .incomplete(needed: 1)
        }

        return bytes.withUnsafeBytes { buffer in
            let first = buffer[offset]
            let length = Self.length(firstByte: first)
            guard available >= length else {
                return .incomplete(needed: length)
            }

            var value = UInt64(first & 0x3f)
            var index = offset &+ 1
            let end = offset &+ length
            while index < end {
                value = value &<< 8 | UInt64(buffer[index])
                index &+= 1
            }
            return .value(value, length: length)
        }
    }

    /// The number of bytes the integer whose first byte is `firstByte` occupies.
    static func length(firstByte: UInt8) -> Int {
        1 &<< Int(firstByte &>> 6)
    }
}
