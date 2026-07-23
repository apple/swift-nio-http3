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

import HTTP3
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP3
import NIOTestUtils
import Testing

import struct NIOQUICHelpers.QUICApplicationErrorCode
import struct NIOQUICHelpers.QUICStopSendingEvent

/// - Warning: Only access on eventloop!
private final class RecorderHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    var readBytes: ByteBuffer = .init()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        self.readBytes.writeImmutableBuffer(bytes)
        context.fireChannelRead(data)
    }
}

/// Records when a QUICStopSendingEvent was sent.
/// - Warning: Only access on eventloop!
private final class StreamCloseTriggerRecorder: ChannelOutboundHandler {
    typealias OutboundIn = Any

    var errorCode: QUICApplicationErrorCode?

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if let event = event as? QUICStopSendingEvent {
            #expect(self.errorCode == nil)
            self.errorCode = event.code
        }
    }
}

struct HTTP3UnidirectionalStreamTypeDecoderHandlerTests {
    private let logger = Logger(label: "HTTP3UnidirectionalStreamTypeDecoderHandlerTests")

    @Test
    func getsStreamType() throws {
        let eventLoop = EmbeddedEventLoop()
        var callbackWasCalled = false
        let handler = HTTP3UnidirectionalStreamTypeDecoderHandler(logger: logger) { type in
            callbackWasCalled = true
            #expect(type == .control)
            return eventLoop.makeSucceededFuture(.ready)
        }
        let channel = EmbeddedChannel(handlers: [handler], loop: eventLoop)

        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(0, strategy: .quic)  // Control streams are type 0
        #expect(buffer.readableBytes == 1)

        try channel.writeInbound(buffer)

        #expect(callbackWasCalled == true)
    }

    @Test
    func getsMultiByteStreamType() throws {
        let eventLoop = EmbeddedEventLoop()
        let recorderHandler = RecorderHandler()
        var callbackWasCalled = false
        let handler = HTTP3UnidirectionalStreamTypeDecoderHandler(logger: logger) { type in
            callbackWasCalled = true
            #expect(type == .unknown(raw: 100000))
            return eventLoop.makeSucceededFuture(.ready)
        }
        let channel = EmbeddedChannel(handlers: [handler, recorderHandler], loop: eventLoop)

        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(100000, strategy: .quic)
        #expect(buffer.readableBytes == 4)

        // We'll drip in the data byte by byte
        let bytes = buffer.readableBytesView.map { $0 }
        for byte in bytes {
            let partBuffer = ByteBuffer(bytes: [byte])
            #expect(partBuffer.readableBytes == 1)
            try channel.writeInbound(partBuffer)
        }

        // We didn't send anything more than the stream type
        #expect(recorderHandler.readBytes.readableBytes == 0)

        #expect(callbackWasCalled == true)
    }

    @Test
    func queuesBytesAfterStreamType() throws {
        let eventLoop = EmbeddedEventLoop()
        let releasePromise = eventLoop.makePromise(of: HTTP3UnidirectionalStreamTypeDecoderHandler.DecodeResult.self)
        let typeHandler = HTTP3UnidirectionalStreamTypeDecoderHandler(logger: logger) { _ in releasePromise.futureResult
        }
        let recorderHandler = RecorderHandler()
        let channel = EmbeddedChannel(handlers: [typeHandler, recorderHandler], loop: eventLoop)

        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(2, strategy: .quic)
        #expect(buffer.readableBytes == 1)

        // Send extra data after the stream type
        buffer.writeString("hello")

        try channel.writeInbound(buffer)

        // everything is queued
        #expect(recorderHandler.readBytes.readableBytes == 0)

        // release the queue
        releasePromise.succeed(.ready)

        // We should see the "hello"
        #expect(recorderHandler.readBytes.readableBytes == 5)  // hello is 5 characters
        let expectedBytes: [UInt8] = [] + "hello".utf8
        #expect(recorderHandler.readBytes.getBytes(at: 0, length: 5) == expectedBytes)

        // handler should remove itself now
        #expect(throws: ChannelPipelineError.notFound) {
            // We only care to know if the future is failed or not. We don't care about the value. We map to value to Void to avoid Sendable warnings.
            try channel.pipeline.handler(type: HTTP3UnidirectionalStreamTypeDecoderHandler.self).map { _ in () }.wait()
        }
    }

    @Test
    func queuesBytesAfterStreamTypeMultiByte() throws {
        // This test specifically is for the scenario where it takes multiple bytes to get the stream type, and each of those bytes comes
        // separately and thus needs to be buffered, but the final incoming bytebuffer, the one which contains the last byte needed for the
        // stream type, also contains extra bytes. We need to make sure those extra bytes make it to the next handler
        let eventLoop = EmbeddedEventLoop()
        let releasePromise = eventLoop.makePromise(of: HTTP3UnidirectionalStreamTypeDecoderHandler.DecodeResult.self)
        let typeHandler = HTTP3UnidirectionalStreamTypeDecoderHandler(logger: logger) { _ in releasePromise.futureResult
        }
        let recorderHandler = RecorderHandler()

        let channel = EmbeddedChannel(handlers: [typeHandler, recorderHandler])

        var firstBuffer = ByteBuffer()
        var secondBuffer = ByteBuffer()
        var thirdBuffer = ByteBuffer()

        // The 4b and b8 together make the quic integer 3000. The 01 and 02 are the extra bytes which should make it into the next handler
        firstBuffer.writeBytes([0x4b])
        secondBuffer.writeBytes([0xb8, 0x01])
        thirdBuffer.writeBytes([0x02])

        try channel.writeInbound(firstBuffer)
        try channel.writeInbound(secondBuffer)
        try channel.writeInbound(thirdBuffer)

        // everything is queued
        #expect(recorderHandler.readBytes.readableBytes == 0)

        // release the queue
        releasePromise.succeed(.ready)

        // We should see the 2 bytes we sent
        #expect(recorderHandler.readBytes.readableBytes == 2)
        #expect(recorderHandler.readBytes.getBytes(at: 0, length: 2) == [0x01, 0x02])

        // handler should remove itself now
        #expect(throws: ChannelPipelineError.notFound) {
            // We only care to know if the future is failed or not. We don't care about the value. We map to value to Void to avoid Sendable warnings.
            try channel.pipeline.handler(type: HTTP3UnidirectionalStreamTypeDecoderHandler.self).map { _ in () }.wait()
        }
    }

    @Test
    func dequeuesBytes() throws {
        let eventLoop = EmbeddedEventLoop()
        let releasePromise = eventLoop.makePromise(of: HTTP3UnidirectionalStreamTypeDecoderHandler.DecodeResult.self)
        let typeHandler = HTTP3UnidirectionalStreamTypeDecoderHandler(logger: logger) { _ in releasePromise.futureResult
        }
        let recorderHandler = RecorderHandler()
        let eventsHandler = EventCounterHandler()
        let channel = EmbeddedChannel(handlers: [typeHandler, recorderHandler, eventsHandler], loop: eventLoop)

        var typeBuffer = ByteBuffer()
        typeBuffer.writeEncodedInteger(2, strategy: .quic)
        #expect(typeBuffer.readableBytes == 1)

        try channel.writeInbound(typeBuffer)

        // Send extra data after the type
        try channel.writeInbound(ByteBuffer(string: "hello"))

        // everything is queued
        #expect(recorderHandler.readBytes.readableBytes == 0)
        // 2 complete calls, because we called writeInbound twice. But the type decoder handler won't forward them yet
        #expect(eventsHandler.channelReadCompleteCalls == 2)
        #expect(eventsHandler.channelReadCalls == 0)

        // release the queue
        releasePromise.succeed(.ready)

        // Now the read comes out, and we have 3 completes in total
        // There is only one read, that's the 'hello'. The type itself is not forwarded
        #expect(eventsHandler.channelReadCalls == 1)
        #expect(eventsHandler.channelReadCompleteCalls == 3)

        // We should see the "hello"
        #expect(recorderHandler.readBytes.readableBytes == 5)  // hello is 5 characters
        let expectedBytes: [UInt8] = [] + "hello".utf8
        #expect(recorderHandler.readBytes.getBytes(at: 0, length: 5) == expectedBytes)

        // handler should remove itself now
        #expect(throws: ChannelPipelineError.notFound) {
            // We only care to know if the future is failed or not. We don't care about the value. We map to value to Void to avoid Sendable warnings.
            try channel.pipeline.handler(type: HTTP3UnidirectionalStreamTypeDecoderHandler.self).map { _ in () }.wait()
        }
    }

    @Test
    func initializationError() throws {
        let eventLoop = EmbeddedEventLoop()
        let releasePromise = eventLoop.makePromise(of: HTTP3UnidirectionalStreamTypeDecoderHandler.DecodeResult.self)
        let typeHandler = HTTP3UnidirectionalStreamTypeDecoderHandler(logger: logger) { _ in releasePromise.futureResult
        }
        let recorderHandler = RecorderHandler()
        let closeTriggerRecorder = StreamCloseTriggerRecorder()
        let inboundEventsHandler = EventCounterHandler()
        let outboundEventsHandler = EventCounterHandler()
        let channel = EmbeddedChannel(
            handlers: [
                closeTriggerRecorder, outboundEventsHandler, typeHandler, recorderHandler, inboundEventsHandler,
            ],
            loop: eventLoop
        )

        var typeBuffer = ByteBuffer()
        typeBuffer.writeEncodedInteger(2, strategy: .quic)
        #expect(typeBuffer.readableBytes == 1)

        try channel.writeInbound(typeBuffer)

        // Send extra data after the type
        try channel.writeInbound(ByteBuffer(string: "hello"))

        // everything is queued
        #expect(recorderHandler.readBytes.readableBytes == 0)
        // 2 complete calls, because we called writeInbound twice. But the type decoder handler won't forward them yet
        #expect(inboundEventsHandler.channelReadCompleteCalls == 2)
        #expect(inboundEventsHandler.channelReadCalls == 0)

        // Fail the promise / abort reading
        releasePromise.fail(
            HTTP3Error(
                code: .streamCreationError,
                message: "test",
                cause: nil,
                errorCode: .streamCreationError,
                location: .here()
            )
        )

        // Nothing has changed w.r.t reads, because we never release the bytes. We just drop them
        #expect(inboundEventsHandler.channelReadCompleteCalls == 2)
        #expect(inboundEventsHandler.channelReadCalls == 0)

        // The channel sends an outbound QUICStopSendingEvent event and an inbound error caught
        #expect(closeTriggerRecorder.errorCode == QUICApplicationErrorCode(.streamCreationError))
        #expect(inboundEventsHandler.errorCaughtCalls == 1)
        #expect(outboundEventsHandler.triggerUserOutboundEventCalls == 1)
    }
}
