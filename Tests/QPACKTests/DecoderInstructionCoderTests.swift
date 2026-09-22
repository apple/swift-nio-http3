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

/// Tests for encoding and decoding the `decoder instructions`.
struct DecoderInstructionCoderTests {
    @Test(arguments: [
        QPACKDecoderInstruction.insertCountIncrement(increment: 10),
        QPACKDecoderInstruction.sectionAcknowledgement(streamID: 20),
        QPACKDecoderInstruction.streamCancellation(streamID: 30),
    ])
    func roundtripEncodeAndDecodeDecoderInstruction(instruction: QPACKDecoderInstruction) throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKDecoderInstruction(instruction)

        // Decode via the decoder under test
        let decoder = QPACKDecoderInstructionDecoder()
        let decoded = try decoder.decode(buffer: &buffer)
        // Assert the roundtrip worked. This means the decoder works correctly
        #expect(decoded == instruction)
        #expect(buffer.readableBytes == 0)
    }
}
