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
@_spi(PackageInternal) import QPACK
import Testing

/// Tests for encoding and decoding the `decoder instructions`.
struct DecoderInstructionCoderTests {
    @Test(arguments: [
        QPACKDecoderInstruction.insertCountIncrement(increment: 10),
        QPACKDecoderInstruction.sectionAcknowledgement(streamID: 20),
        QPACKDecoderInstruction.streamCancellation(streamID: 30),
    ])
    func roundtripEncodeAndDecodeDecoderInstruction(instruction: QPACKDecoderInstruction) throws {
        // Encode "manually". We can trust the result of this because it's tested elsewhere as a unit
        var expectedResult = ByteBuffer()
        expectedResult.writeQPACKDecoderInstruction(instruction)

        // Encode via the encoder which is under test
        var testBuffer = ByteBuffer()
        let encoder = QPACKDecoderInstructionEncoder()
        encoder.encode(data: instruction, out: &testBuffer)

        // Assert the results are same. This means the encoder works correctly
        #expect(testBuffer == expectedResult)

        // Decode via the decoder under test
        let decoder = QPACKDecoderInstructionDecoder()
        let decoded = try decoder.decode(buffer: &testBuffer)
        // Assert the roundtrip worked. This means the decoder works correctly
        #expect(decoded == instruction)
    }
}
