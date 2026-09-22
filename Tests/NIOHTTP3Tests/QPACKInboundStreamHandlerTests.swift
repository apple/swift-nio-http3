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

@_spi(PackageInternal) import HTTP3
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import NIOHTTP3
@_spi(PackageInternal) @testable import QPACK

/// Collects the errors a QPACK inbound stream handler reports to its delegate.
private final class TestQPACKInboundStreamDelegate: QPACKInboundStreamDelegate {
    let errors = NIOLockedValueBox<[HTTP3Error]>([])

    func onError(_ error: HTTP3Error) {
        self.errors.withLockedValue { $0.append(error) }
    }
}

struct QPACKInboundEncoderStreamHandlerTests {
    /// A peer which respects our zero `SETTINGS_QPACK_MAX_TABLE_CAPACITY` may still set the capacity to zero,
    /// which is a no-op.
    @available(anyAppleOS 26.0, *)
    @Test func settingTheDynamicTableCapacityToZeroIsAccepted() throws {
        let delegate = TestQPACKInboundStreamDelegate()
        let channel = EmbeddedChannel(
            handler: QPACKInboundEncoderStreamHandler(delegate: delegate),
            loop: EmbeddedEventLoop()
        )

        try channel.writeInbound(ByteBuffer(instruction: .setDynamicTableCapacity(0)))

        #expect(delegate.errors.withLockedValue { $0 }.isEmpty)
        #expect(try channel.finish().isClean)
    }

    /// Anything which implies a dynamic table is a connection error.
    @available(anyAppleOS 26.0, *)
    @Test(arguments: [
        QPACKEncoderInstruction.setDynamicTableCapacity(1024),
        QPACKEncoderInstruction.insertWithLiteralName(name: "cookie", value: "test"),
        QPACKEncoderInstruction.insertWithNameReference(.staticTable, relativeIndex: 0, value: "test"),
        QPACKEncoderInstruction.duplicateEntry(relativeIndex: 0),
    ])
    func anyOtherInstructionIsAConnectionError(instruction: QPACKEncoderInstruction) throws {
        let delegate = TestQPACKInboundStreamDelegate()
        let channel = EmbeddedChannel(
            handler: QPACKInboundEncoderStreamHandler(delegate: delegate),
            loop: EmbeddedEventLoop()
        )

        expectH3Error(code: .qpackEncoderStreamError, h3ErrorCode: .qpackEncoderStreamError) {
            try channel.writeInbound(ByteBuffer(instruction: instruction))
        }

        let errors = delegate.errors.withLockedValue { $0 }
        try #require(errors.count == 1)
        #expect(errors[0].h3ErrorCode == .qpackEncoderStreamError)
    }

    /// An instruction which can't be parsed at all is also a connection error.
    @available(anyAppleOS 26.0, *)
    @Test func undecodableInstructionIsAConnectionError() throws {
        let delegate = TestQPACKInboundStreamDelegate()
        let channel = EmbeddedChannel(
            handler: QPACKInboundEncoderStreamHandler(delegate: delegate),
            loop: EmbeddedEventLoop()
        )

        var buffer = ByteBuffer()
        // 0x20 followed by UInt.max means set the dynamic table capacity to a value we can't even represent.
        buffer.writeQPACKPrefixedInteger(UInt.max, prefix: 5, prefixBits: 0x20)
        #expect(throws: (any Error).self) { try channel.writeInbound(buffer) }

        let errors = delegate.errors.withLockedValue { $0 }
        try #require(errors.count == 1)
        #expect(errors[0].h3ErrorCode == .qpackEncoderStreamError)
    }
}

struct QPACKInboundDecoderStreamHandlerTests {
    /// This endpoint's encoder never references the dynamic table, so the peer's decoder has nothing to tell
    /// us: any instruction is a connection error.
    @Test(arguments: [
        QPACKDecoderInstruction.sectionAcknowledgement(streamID: 0),
        QPACKDecoderInstruction.streamCancellation(streamID: 0),
        QPACKDecoderInstruction.insertCountIncrement(increment: 1),
    ])
    func anyInstructionIsAConnectionError(instruction: QPACKDecoderInstruction) throws {
        let delegate = TestQPACKInboundStreamDelegate()
        let channel = EmbeddedChannel(
            handler: QPACKInboundDecoderStreamHandler(delegate: delegate),
            loop: EmbeddedEventLoop()
        )

        expectH3Error(code: .qpackDecoderStreamError, h3ErrorCode: .qpackDecoderStreamError) {
            try channel.writeInbound(ByteBuffer(instruction: instruction))
        }

        let errors = delegate.errors.withLockedValue { $0 }
        try #require(errors.count == 1)
        #expect(errors[0].h3ErrorCode == .qpackDecoderStreamError)
    }
}

extension ByteBuffer {
    @available(anyAppleOS 26.0, *)
    fileprivate init(instruction: QPACKEncoderInstruction) {
        self.init()
        self.writeQPACKEncoderInstruction(instruction, preferHuffmanEncoding: false)
    }

    fileprivate init(instruction: QPACKDecoderInstruction) {
        self.init()
        self.writeQPACKDecoderInstruction(instruction)
    }
}
