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

import DequeModule
import HTTP3
import HTTPTypes
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOExtras
import NIOHTTP3
import NIOQUICHelpers
import QPACK
import Testing

struct NIOHTTP3StreamHandlerTests {
    private var testRequestHeaderFields: [HTTPField] = [
        .init(name: .method, value: "GET"),
        .init(name: .path, value: "/"),
        .init(name: .authority, value: "test"),
        .init(name: .scheme, value: "http"),
    ]

    private var testRequestHeaderFrame: HTTP3Frame {
        .headers(self.testRequestHeaderFields)
    }

    private var testRequestPartialHeader: HTTP3PartialFrame.Headers {
        .init(fieldSection: StaticQPACKEncoder().encode(headers: self.testRequestHeaderFields))
    }

    private var testRequestPartialHeaderBytes: ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeHTTP3PartialFrame(.headers(self.testRequestPartialHeader), preferHuffmanEncoding: false)
        return buffer
    }

    private let testEncoderClosure: ([HTTPField], QUICStreamID) -> HTTP3PartialFrame.Headers = { fields, _ in
        let fieldSection = StaticQPACKEncoder().encode(headers: fields)
        return HTTP3PartialFrame.Headers(fieldSection: fieldSection)
    }

    private let logger = Logger(label: "NIOHTTP3StreamHandlerTests")

    @Test
    func receiveInvalidHeaders() throws {
        var headerToDecode: HTTP3PartialFrame.Headers?
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in headerToDecode = field },
            onStreamClosed: { eof, _, _ in Issue.record("Unexpected closure of stream. Saw EOF: \(eof)") },
            onConnectionError: { Issue.record("Unexpected error \($0)") },
            logger: self.logger
        )
        let eventLoop = EmbeddedEventLoop()
        let recorderPromise = eventLoop.makePromise(of: [HTTP3Frame].self)
        let recorder = InboundDataRecorder(promise: recorderPromise, targetCount: 1)
        let channel = EmbeddedChannel(handlers: [handler, recorder], loop: eventLoop)

        // Read in a test header
        try channel.writeInbound(self.testRequestPartialHeaderBytes)

        // Give the qpack result
        let testError = HTTP3Error(
            code: .qpackDecoderError,
            message: "test",
            cause: nil,
            errorCode: .internalError,
            location: .here()
        )
        guard let headerToDecode else {
            Issue.record("Expected to have a header to decode")
            return
        }
        handler.onQPACKDecodeError(testError, forHeaders: headerToDecode)

        expectH3Error(code: .qpackDecoderError, h3ErrorCode: .internalError, message: "test") {
            _ = try recorderPromise.futureResult.wait()
        }
    }

    /// Receive headers which can't yet be decoded, but can be later.
    @Test
    func receiveHeadersWhichNeedInstructions() throws {
        var headerToDecode: HTTP3PartialFrame.Headers?
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in headerToDecode = field },
            onStreamClosed: { eof, _, _ in Issue.record("Unexpected closure of stream. Saw EOF: \(eof)") },
            onConnectionError: { Issue.record("Unexpected error \($0)") },
            logger: self.logger
        )
        let eventLoop = EmbeddedEventLoop()

        // Record events into a Deque so we can pop them as we expect them and assert nothing left at the end.
        let seenEvents = NIOLockedValueBox<Deque<DebugInboundEventsHandler.Event>>([])
        let eventRecorder = DebugInboundEventsHandler { event, _ in
            seenEvents.withLockedValue { $0.append(event) }
        }
        let channel = EmbeddedChannel(handlers: [handler, eventRecorder], loop: eventLoop)
        #expect(seenEvents.popFirst()?.isChannelRegistered == true)

        // Read in a test header
        try channel.writeInbound(self.testRequestPartialHeaderBytes)

        // Make the result available
        guard let headerToDecode else {
            Issue.record("Expected to have a header to decode")
            return
        }
        handler.onQPACKDecodeResult(fields: self.testRequestHeaderFields, forHeaders: headerToDecode)

        // Make sure we read the right value
        guard let readFrameAny = seenEvents.popFirst()?.readValue else {
            Issue.record("Expected to read a frame")
            return
        }
        // There's no API to unwrap a NIOAny ... unless you ask a handler to do it
        let readFrame = handler.unwrapOutboundIn(readFrameAny)
        #expect(readFrame == self.testRequestHeaderFrame)
        // Make sure we also fired a readComplete
        #expect(seenEvents.popFirst()?.isChannelReadComplete == true)
        #expect(seenEvents.isEmpty())
    }

    @Test
    func receiveUnknownFrameFollowedByHeaders() throws {
        var headerToDecode: HTTP3PartialFrame.Headers?
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in headerToDecode = field },
            onStreamClosed: { eof, _, _ in Issue.record("Unexpected closure of stream. Saw EOF: \(eof)") },
            onConnectionError: { Issue.record("Unexpected error \($0)") },
            logger: self.logger
        )
        let eventLoop = EmbeddedEventLoop()

        // Record events into a Deque so we can pop them as we expect them and assert nothing left at the end.
        let seenEvents = NIOLockedValueBox<Deque<DebugInboundEventsHandler.Event>>([])
        let eventRecorder = DebugInboundEventsHandler { event, _ in
            seenEvents.withLockedValue { $0.append(event) }
        }
        let channel = EmbeddedChannel(handlers: [handler, eventRecorder], loop: eventLoop)
        #expect(seenEvents.popFirst()?.isChannelRegistered == true)

        // Read in an unknown frame followed by a test header
        let testUnknownFrameBytes: [UInt8] = [0x40, 0xdb, 0x00]
        var bufferToWriteIn = ByteBuffer(bytes: testUnknownFrameBytes)
        bufferToWriteIn.writeImmutableBuffer(self.testRequestPartialHeaderBytes)
        try channel.writeInbound(bufferToWriteIn)

        // Make the QPACK result available
        guard let headerToDecode else {
            Issue.record("Expected to have a header to decode")
            return
        }
        handler.onQPACKDecodeResult(fields: self.testRequestHeaderFields, forHeaders: headerToDecode)

        // Make sure we read the right value
        guard let readFrameAny = seenEvents.popFirst()?.readValue else {
            Issue.record("Expected to read a frame")
            return
        }
        // There's no API to unwrap a NIOAny ... unless you ask a handler to do it
        let readFrame = handler.unwrapOutboundIn(readFrameAny)
        #expect(readFrame == self.testRequestHeaderFrame)
        // Make sure we also fired a readComplete
        #expect(seenEvents.popFirst()?.isChannelReadComplete == true)
        #expect(seenEvents.isEmpty())
    }

    @Test
    func write() throws {
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .control, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in Issue.record("Unexpected header decode \(field)") },
            onStreamClosed: { eof, _, _ in Issue.record("Unexpected closure of stream. Saw EOF: \(eof)") },
            onConnectionError: { Issue.record("Unexpected error \($0)") },
            logger: self.logger
        )
        let eventLoop = EmbeddedEventLoop()
        let recorderPromise = eventLoop.makePromise(of: [ByteBuffer].self)
        let recorder = OutboundDataRecorder(promise: recorderPromise, targetCount: 1)
        let channel = EmbeddedChannel(handlers: [recorder, handler], loop: eventLoop)

        // write out a settings frame
        try channel.writeOutbound(HTTP3Frame.settings(.init()))
        let writtenBytes = try recorderPromise.futureResult.wait()
        // The type is 4, the length is 0, but the 0 is encoded in 2 bytes because of how `ByteBuffer/writeLengthPrefixed` works
        #expect(writtenBytes == [.init(bytes: [4, 0x40, 0])])
    }

    /// Write a frame which would result in a stream error.
    @Test
    func writeStreamError() throws {
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in Issue.record("Unexpected header decode \(field)") },
            onStreamClosed: { eof, _, _ in Issue.record("Unexpected closure of stream. Saw EOF: \(eof)") },
            onConnectionError: { Issue.record("Unexpected error \($0)") },
            logger: self.logger
        )
        let eventLoop = EmbeddedEventLoop()
        let errorPromise = eventLoop.makePromise(of: (any Error).self)
        let errorRecorder = InboundErrorRecorder(errorPromise: errorPromise)

        let channel = EmbeddedChannel(handlers: [handler, errorRecorder], loop: eventLoop)

        // write out response (invalid because we didn't get a request)
        expectH3Error(code: .malformedMessage, h3ErrorCode: .messageError) {
            try channel.writeOutbound(HTTP3Frame.headers([]))
        }
        expectH3Error(code: .malformedMessage, h3ErrorCode: .messageError) {
            let thrownError = try errorPromise.futureResult.wait()
            throw thrownError
        }
    }

    /// Write a frame which would result in a connection error.
    @Test
    func writeConnectionError() throws {
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in Issue.record("Unexpected header decode \(field)") },
            onStreamClosed: { eof, _, _ in Issue.record("Unexpected closure of stream. Saw EOF: \(eof)") },
            onConnectionError: { Issue.record("Unexpected error \($0)") },
            logger: self.logger
        )
        let eventLoop = EmbeddedEventLoop()
        let errorPromise = eventLoop.makePromise(of: (any Error).self)
        let errorRecorder = InboundErrorRecorder(errorPromise: errorPromise)

        let channel = EmbeddedChannel(handlers: [handler, errorRecorder], loop: eventLoop)

        // write out a settings frame. This is invalid, because this is a request stream
        expectH3Error(code: .unexpectedFrame, h3ErrorCode: .frameUnexpected) {
            try channel.writeOutbound(HTTP3Frame.settings(.init()))
        }
        expectH3Error(code: .unexpectedFrame, h3ErrorCode: .frameUnexpected) {
            let thrownError = try errorPromise.futureResult.wait()
            throw thrownError
        }
    }

    /// Write a frame after closing the channel
    @Test
    func writeAfterClose() throws {
        let eventLoop = EmbeddedEventLoop()
        let sawEOF = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in Issue.record("Unexpected header decode \(field)") },
            onStreamClosed: { eof, _, _ in sawEOF.succeed(eof) },
            onConnectionError: { Issue.record("Unexpected error \($0)") },
            logger: self.logger
        )
        let errorPromise = eventLoop.makePromise(of: (any Error).self)
        let errorRecorder = InboundErrorRecorder(errorPromise: errorPromise)

        let channel = EmbeddedChannel(handlers: [handler, errorRecorder], loop: eventLoop)
        try channel.close().wait()

        // write out response (invalid because we didn't get a request)
        #expect(throws: ChannelError.ioOnClosedChannel) {
            try channel.writeOutbound(HTTP3Frame.headers([]))
        }

        // onStreamClosed will be called above which will succeed this promise
        // Expect false, we never gave an eof
        #expect(try !sawEOF.futureResult.wait())
    }

    @Test
    func connectionError() throws {
        let eventLoop = EmbeddedEventLoop()
        let connectionErrorPromise = eventLoop.makePromise(of: HTTP3Error.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .control, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .control,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in Issue.record("Unexpected header decode \(field)") },
            onStreamClosed: { eof, _, _ in Issue.record("Unexpected closure of stream. Saw EOF: \(eof)") },
            onConnectionError: { connectionErrorPromise.succeed($0) },
            logger: self.logger
        )
        let channel = EmbeddedChannel(handlers: [handler], loop: eventLoop)

        // Read in an invalid settings frame
        // Type 4, length 1, identifier 1. Missing value
        let badSettingsBuffer = ByteBuffer(bytes: [4, 1, 1])
        try channel.writeInbound(badSettingsBuffer)

        let error = try connectionErrorPromise.futureResult.wait()
        expectH3ErrorEqual(
            error: error,
            expectedCode: .invalidFramePayload,
            expectedH3ErrorCode: .frameError,
            expectedMessage: "Setting value is not a valid QUIC variable-length integer"
        )
    }

    @Test
    func channelInactive() throws {
        let eventLoop = EmbeddedEventLoop()
        // The bool is true if the close was clean, ie we saw EOF
        let streamClosedPromise = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .control, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .control,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in Issue.record("Unexpected header decode \(field)") },
            onStreamClosed: { eof, _, _ in streamClosedPromise.succeed(eof) },
            onConnectionError: { Issue.record("Unexpected connection error \($0)") },
            logger: self.logger
        )
        let channel = EmbeddedChannel(handlers: [handler], loop: eventLoop)
        #expect(try channel.finish().isClean)
        let sawEOF = try streamClosedPromise.futureResult.wait()
        #expect(sawEOF == false)
    }

    @Test
    func channelInactiveAfterEOF() throws {
        let eventLoop = EmbeddedEventLoop()
        // The bool is true if the close was clean, ie we saw EOF
        let streamClosedPromise = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .control, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .control,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { field, _ in Issue.record("Unexpected header decode \(field)") },
            onStreamClosed: { eof, _, _ in streamClosedPromise.succeed(eof) },
            onConnectionError: { Issue.record("Unexpected connection error \($0)") },
            logger: self.logger
        )
        let channel = EmbeddedChannel(handlers: [handler], loop: eventLoop)
        // We fire an input closed, which means the bool will be true this time, unlike the test above.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        #expect(try channel.finish().isClean)
        let sawEOF = try streamClosedPromise.futureResult.wait()
        #expect(sawEOF == true)
    }

    @Test
    func channelInactiveAfterEOFWaitingForDecode() throws {
        let eventLoop = EmbeddedEventLoop()
        // The bool is true if the close was clean, ie we saw EOF
        let streamClosedPromise = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { _, _ in },
            onStreamClosed: { eof, _, _ in streamClosedPromise.succeed(eof) },
            onConnectionError: { Issue.record("Unexpected connection error \($0)") },
            logger: self.logger
        )
        let channel = EmbeddedChannel(handlers: [handler], loop: eventLoop)
        // The channel here is a server-side request stream channel.
        // We will write in a single, QPACK encoded request head, but will not yet decode it.i.e. we will simulate the
        // QPACK decode being blocked.
        // Then we will trigger input closed, and then channel inactive.
        // Usually, channel inactive after input closed means the close is clean.
        // But here, it is not clean, because we had to abort waiting for a QPACK decode.
        // Read order must be retained, the inputClose cannot overtake the headers, and we can't read the headers.
        // And anyway semantically, this must be treated as an unclean close, we must inform the remote QPACK encoder
        // of the stream cancellation because there are potentially other un-decoded QPACK fields.

        class EnsureNoReadHandler: ChannelInboundHandler {
            typealias InboundIn = Never

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                Issue.record("Expected no reads, but got \(data)")
            }

            func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                Issue.record("Expected no events, but got \(event)")
            }
        }

        // Read in a test header
        try channel.writeInbound(self.testRequestPartialHeaderBytes)

        // Close the input
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Close
        #expect(try channel.finish().isClean)
        let sawEOF = try streamClosedPromise.futureResult.wait()
        #expect(sawEOF == false)
    }

    @Test
    // Make sure that if we have buffered data which we didn't fire read for, then we do so before forwarding channel inactive.
    func flushBuffersWhenChannelInactive() throws {
        let eventLoop = EmbeddedEventLoop()
        // The bool is true if the close was clean, ie we saw EOF
        let streamClosedPromise = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { _, _ in },
            onStreamClosed: { eof, _, _ in streamClosedPromise.succeed(eof) },
            onConnectionError: { Issue.record("Unexpected connection error \($0)") },
            logger: self.logger
        )
        // Record events into a Deque so we can pop them as we expect them and assert nothing left at the end.
        let seenEvents = NIOLockedValueBox<Deque<DebugInboundEventsHandler.Event>>([])
        let eventRecorder = DebugInboundEventsHandler { event, _ in
            seenEvents.withLockedValue { $0.append(event) }
        }
        let channel = EmbeddedChannel(handlers: [handler, eventRecorder], loop: eventLoop)

        // We can't insert an inactive after a header because the qpack decode immediately triggers a channel read.
        // So we have to do it after a data instead.
        // But we can't send a data until we've sent a header, because HTTP/3 rules.
        // Read in a test header
        try channel.writeInbound(self.testRequestPartialHeaderBytes)

        #expect(seenEvents.popFirst()?.isChannelRegistered == true)
        #expect(seenEvents.isEmpty())

        // Give the stream the header decode result
        handler.onQPACKDecodeResult(fields: self.testRequestHeaderFields, forHeaders: self.testRequestPartialHeader)

        guard let headerReadEvent = seenEvents.popFirst()?.readValue else {
            Issue.record("Expected a read event")
            return
        }
        // We see the channel read and read complete
        #expect(handler.unwrapOutboundIn(headerReadEvent) == self.testRequestHeaderFrame)
        #expect(seenEvents.popFirst()?.isChannelReadComplete == true)

        var dataBytes = ByteBuffer()
        dataBytes.writeHTTP3PartialFrame(.data(.init(string: "hello world")), preferHuffmanEncoding: false)
        channel.pipeline.fireChannelRead(dataBytes)
        // We do not fire a read complete. So the bytes get buffered, but nothing comes out.
        #expect(seenEvents.isEmpty())

        // Close
        #expect(try !channel.finish().isClean)  // Close is not clean due to reads reaching the end of the pipeline
        let sawEOF = try streamClosedPromise.futureResult.wait()
        #expect(sawEOF == false)  // We did not see an EOF before close

        // Now we see the data read
        guard let dataReadEvent = seenEvents.popFirst()?.readValue else {
            Issue.record("Expected a read event")
            return
        }
        // We see the channel read and read complete and THEN the inactive
        #expect(handler.unwrapOutboundIn(dataReadEvent) == .data(.init(string: "hello world")))
        #expect(seenEvents.popFirst()?.isChannelReadComplete == true)
        #expect(seenEvents.popFirst()?.isChannelInactive == true)
        #expect(seenEvents.popFirst()?.isChannelUnregistered == true)
        #expect(seenEvents.isEmpty())
    }

    @Test
    func testMoreInputAfterInputClosed() async throws {
        let eventLoop = EmbeddedEventLoop()

        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackEncoder: testEncoderClosure,
            qpackDecoder: { _, _ in },
            onStreamClosed: { _, _, _ in },
            onConnectionError: { Issue.record("Unexpected connection error \($0)") },
            logger: self.logger
        )
        let recorderPromise = eventLoop.makePromise(of: [HTTP3Frame].self)
        let recorder = InboundDataRecorder(promise: recorderPromise, targetCount: 2)
        let channel = EmbeddedChannel(handlers: [handler, recorder], loop: eventLoop)

        // Headers frame
        try channel.writeInbound(self.testRequestPartialHeaderBytes)
        handler.onQPACKDecodeResult(fields: self.testRequestHeaderFields, forHeaders: self.testRequestPartialHeader)

        // Input close
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        try handler.channelReadComplete(context: channel.pipeline.syncOperations.context(handler: handler))

        // Data frame
        try channel.writeInbound(ByteBuffer(bytes: [0, 4, 1, 2, 3, 4]))

        try await Task.sleep(for: .milliseconds(500), tolerance: .zero)
        // We only see the headers frame, not the data
        let seenFrames = recorder.getDataOnEventloop()
        #expect(seenFrames.count == 1)
    }
}
