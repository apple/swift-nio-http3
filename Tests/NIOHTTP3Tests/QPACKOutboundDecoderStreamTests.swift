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

import NIOCore
import NIOEmbedded
@_spi(PackageInternal) import QPACK
import Testing

@testable import NIOHTTP3

struct QPACKOutboundStreamTests {
    @available(anyAppleOS 26.0, *)
    @Test func sendEncoderInstruction() throws {
        let channel = EmbeddedChannel()
        var wrapper = QPACKOutboundEncoderStream(channel: channel, preferHuffmanEncoding: true)
        wrapper.sendInstructions(CollectionOfOne(.setDynamicTableCapacity(300)))

        let message = try #require(try channel.readOutbound(as: ByteBuffer.self))

        let decoder = NIOSingleStepByteToMessageProcessor(QPACKEncoderInstructionDecoder())
        var dynamicTableReceived = false
        try decoder.process(buffer: message) { instruction in
            switch instruction {
            case .setDynamicTableCapacity(let capacity):
                #expect(capacity == 300)
                dynamicTableReceived = true

            case .duplicateEntry, .insertWithLiteralName, .insertWithNameReference:
                Issue.record("Unexpeced instruction: \(instruction)")
            }
        }
        #expect(dynamicTableReceived)
    }

    @available(anyAppleOS 26.0, *)
    @Test func sendDecoderInstruction() throws {
        let channel = EmbeddedChannel()
        var wrapper = QPACKOutboundDecoderStream(channel: channel)
        wrapper.sendInstruction(.streamCancellation(streamID: 6))

        let message = try #require(try channel.readOutbound(as: ByteBuffer.self))

        let decoder = NIOSingleStepByteToMessageProcessor(QPACKDecoderInstructionDecoder())
        var streamIDCancellationReceived = false
        try decoder.process(buffer: message) { instruction in
            switch instruction {
            case .streamCancellation(let streamID):
                #expect(streamID == 6)
                streamIDCancellationReceived = true

            case .insertCountIncrement, .sectionAcknowledgement:
                Issue.record("Unexpeced instruction: \(instruction)")
            }
        }
        #expect(streamIDCancellationReceived)
    }
}
