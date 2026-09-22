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

import HTTPTypes
import NIOCore
import Testing

@_spi(PackageInternal) @testable import QPACK

/// Tests for encoding and decoding the `encoder instructions`.
struct EncoderInstructionCoderTests {
    @available(anyAppleOS 26.0, *)
    @Test(
        arguments: [
            QPACKEncoderInstruction.insertWithNameReference(.staticTable, relativeIndex: 10, value: "a"),
            QPACKEncoderInstruction.setDynamicTableCapacity(10),
            QPACKEncoderInstruction.duplicateEntry(relativeIndex: 10),
            QPACKEncoderInstruction.insertWithLiteralName(name: "bla", value: "bla"),
        ],
        [true, false]
    )
    func roundtripEncodeAndDecodeEncoderInstruction(
        instruction: QPACKEncoderInstruction,
        preferHuffmanEncoding: Bool
    ) throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKEncoderInstruction(instruction, preferHuffmanEncoding: preferHuffmanEncoding)

        // Decode via the decoder under test
        let decoder = QPACKEncoderInstructionDecoder()
        let decoded = try decoder.decode(buffer: &buffer)
        // Assert the roundtrip worked. This means the decoder works correctly
        #expect(decoded == instruction)
        #expect(buffer.readableBytes == 0)
    }
}
