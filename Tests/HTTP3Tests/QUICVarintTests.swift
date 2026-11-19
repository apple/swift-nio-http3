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

import Testing

@testable import HTTP3

/// An encoded integer and the value it holds.
struct EncodedVarint: Sendable, CustomTestStringConvertible {
    var bytes: [UInt8]
    var value: UInt64

    var testDescription: String {
        "\(self.value) in \(self.bytes.count) bytes"
    }

    /// RFC 9000 Appendix A.1's examples, and the largest value of each length.
    static let examples: [EncodedVarint] = [
        EncodedVarint(bytes: [0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c], value: 151_288_809_941_952_652),
        EncodedVarint(bytes: [0x9d, 0x7f, 0x3e, 0x7d], value: 494_878_333),
        EncodedVarint(bytes: [0x7b, 0xbd], value: 15_293),
        EncodedVarint(bytes: [0x25], value: 37),
        // RFC 9000 § 16: values do not need to be encoded on the minimum number of bytes.
        EncodedVarint(bytes: [0x40, 0x25], value: 37),
        EncodedVarint(bytes: [0x80, 0x00, 0x00, 0x25], value: 37),
        EncodedVarint(bytes: [0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x25], value: 37),
        EncodedVarint(bytes: [0x00], value: 0),
        EncodedVarint(bytes: [0x3f], value: 63),
        EncodedVarint(bytes: [0x7f, 0xff], value: 16_383),
        EncodedVarint(bytes: [0xbf, 0xff, 0xff, 0xff], value: 1_073_741_823),
        EncodedVarint(bytes: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], value: (1 << 62) - 1),
    ]
}

struct QUICVarintTests {
    @available(anyAppleOS 27, *)
    @Test func lengthComesFromTheTwoMostSignificantBits() {
        for byte in UInt8.min...UInt8.max {
            let expected = [1, 2, 4, 8][Int(byte >> 6)]
            #expect(QUICVarint.length(firstByte: byte) == expected, "first byte \(byte)")
        }
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: EncodedVarint.examples)
    func readsValue(_ encoded: EncodedVarint) {
        #expect(QUICVarint.length(firstByte: encoded.bytes[0]) == encoded.bytes.count)
        #expect(QUICVarint.read(encoded.bytes.span.bytes, at: 0) == .value(encoded.value, length: encoded.bytes.count))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: EncodedVarint.examples)
    func readsValueAtOffsetIgnoringSurroundingBytes(_ encoded: EncodedVarint) {
        let bytes: [UInt8] = [0xff, 0x00, 0x40] + encoded.bytes + [0xff, 0xff]
        #expect(QUICVarint.read(bytes.span.bytes, at: 3) == .value(encoded.value, length: encoded.bytes.count))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: EncodedVarint.examples)
    func truncatedValueIsIncomplete(_ encoded: EncodedVarint) {
        // `needed` is the integer's whole length, counted from the offset, at every truncation point.
        for available in 1..<encoded.bytes.count {
            let truncated = Array(encoded.bytes.prefix(available))
            #expect(
                QUICVarint.read(truncated.span.bytes, at: 0) == .incomplete(needed: encoded.bytes.count),
                "\(available) bytes"
            )
            #expect(QUICVarint.read(([0xff] + truncated).span.bytes, at: 1) == .incomplete(needed: encoded.bytes.count))
        }
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: [0, 1, 4])
    func offsetAtTheEndIsIncomplete(count: Int) {
        let bytes = [UInt8](repeating: 0, count: count)
        #expect(QUICVarint.read(bytes.span.bytes, at: count) == .incomplete(needed: 1))
    }
}
