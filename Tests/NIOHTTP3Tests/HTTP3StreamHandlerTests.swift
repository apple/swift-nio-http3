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
import HTTPTypes
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOExtras
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK
import Testing

@_spi(PackageInternal) @testable import HTTP3
@testable import NIOHTTP3

final class TestDelegate: HTTP3StreamDelegate {
    static func makeUnexpectedStreamClose() -> (Bool, QUICStreamID, HTTP3StreamType.Framed) -> Void {
        { eof, _, _ in
            Issue.record("Unexpected closure of stream. Saw EOF: \(eof)")
        }
    }

    static func makeUnexpectedConnectionError() -> (any Error) -> Void {
        { error in
            Issue.record("Unexpected error \(error)")
        }
    }

    let _onStreamClosed: (Bool, QUICStreamID, HTTP3StreamType.Framed) -> Void
    let _onConnectionError: (HTTP3Error) -> Void

    init(
        onStreamClosed: @escaping (Bool, QUICStreamID, HTTP3StreamType.Framed) -> Void =
            TestDelegate.makeUnexpectedStreamClose(),
        onConnectionError: @escaping (HTTP3Error) -> Void = TestDelegate.makeUnexpectedConnectionError()
    ) {
        self._onStreamClosed = onStreamClosed
        self._onConnectionError = onConnectionError
    }

    func onStreamClosed(_ sawEOF: Bool, streamID: QUICStreamID, streamType: HTTP3StreamType.Framed) {
        self._onStreamClosed(sawEOF, streamID, streamType)
    }

    func onConnectionError(_ error: HTTP3Error) {
        self._onConnectionError(error)
    }
}

/// A mock ``HTTP3/QPACKConnectionDelegate`` for tests which exercise ``HTTP3StreamHandler`` in isolation.
final class TestQPACKConnectionDelegate: HTTP3.QPACKConnectionDelegate {

    static func makeUnexpectedQPACKConnectionErrorHandler() -> (HTTP3Error) -> Void {
        { error in
            Issue.record("Unexpected QPACK connection error \(error)")
        }
    }

    let _connectionError: (HTTP3Error) -> Void
    let _makeOutboundEncoderStream: () -> Void

    /// The number of times the coder asked for an outbound encoder stream.
    private(set) var madeOutboundEncoderStreamCount = 0

    init(
        onConnectionError: @escaping (HTTP3Error) -> Void =
            TestQPACKConnectionDelegate.makeUnexpectedQPACKConnectionErrorHandler(),
        onMakeOutboundEncoderStream: @escaping () -> Void = {}
    ) {
        self._connectionError = onConnectionError
        self._makeOutboundEncoderStream = onMakeOutboundEncoderStream
    }

    func connectionError(_ error: HTTP3Error) {
        self._connectionError(error)
    }

    func makeOutboundEncoderStream() {
        self.madeOutboundEncoderStreamCount += 1
        self._makeOutboundEncoderStream()
    }
}

/// Make a ``QPACKCoder`` suitable for handing to a ``HTTP3StreamHandler`` under test.
///
/// Pass a `decoderStreamChannel` if the test drives a decode which references the dynamic table: the coder writes
/// the resulting acknowledgements to that channel, and traps if it has no outbound decoder stream at all.
@available(anyAppleOS 26.0, *)
func makeTestQPACKCoder(
    encoderMaxTableSize: Int = 4096,
    decoderMaxTableSize: Int = 4096,
    decoderMaxBlockedStreams: Int = 16,
    connectionDelegate: TestQPACKConnectionDelegate = TestQPACKConnectionDelegate(),
    decoderStreamChannel: EmbeddedChannel? = nil
) -> NIOQPACKCoder<TestQPACKConnectionDelegate, TestDelegate> {
    let coder = NIOQPACKCoder<TestQPACKConnectionDelegate, TestDelegate>(
        encoderMaxTableSize: encoderMaxTableSize,
        decoderMaxTableSize: decoderMaxTableSize,
        decoderMaxBlockedStreams: decoderMaxBlockedStreams,
        errorDelegate: connectionDelegate
    )
    if let decoderStreamChannel {
        coder.outboundDecoderStreamReady(QPACKOutboundDecoderStream(channel: decoderStreamChannel))
    }
    return coder
}

@available(anyAppleOS 26.0, *)
extension EmbeddedChannel {
    /// Drain everything a ``QPACKOutboundDecoderStream`` has written to this channel, decoded back into
    /// instructions.
    fileprivate func readAllDecoderInstructions() throws -> [QPACKDecoderInstruction] {
        let processor = NIOSingleStepByteToMessageProcessor(QPACKDecoderInstructionDecoder())
        var instructions = [QPACKDecoderInstruction]()
        while let buffer = try self.readOutbound(as: ByteBuffer.self) {
            try processor.process(buffer: buffer) { instructions.append($0) }
        }
        return instructions
    }
}

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

    @available(anyAppleOS 26.0, *)
    private var testRequestPartialHeaderBytes: ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeHTTP3PartialFrame(.headers(self.testRequestPartialHeader), preferHuffmanEncoding: false)
        return buffer
    }

    @available(anyAppleOS 26.0, *)
    private var testUndecodableRequestPartialHeaderBytes: ByteBuffer {
        var fieldSection = StaticQPACKEncoder().encode(headers: self.testRequestHeaderFields)
        // A relative index of 0 against a base of 0 is absolute index -1, which is never in the table.
        fieldSection.lines.append(.indexed(.dynamicTable, index: 0))
        var buffer = ByteBuffer()
        buffer.writeHTTP3PartialFrame(
            .headers(.init(fieldSection: fieldSection)),
            preferHuffmanEncoding: false
        )
        return buffer
    }

    private let testEncoderClosure: ([HTTPField], QUICStreamID) -> HTTP3PartialFrame.Headers = { fields, _ in
        let fieldSection = StaticQPACKEncoder().encode(headers: fields)
        return HTTP3PartialFrame.Headers(fieldSection: fieldSection)
    }

    /// The single field carried by ``testBlockedRequestPartialHeaderBytes``.
    ///
    /// It is the entry inserted by ``testUnblockingEncoderInstruction``.
    private var testBlockedRequestHeaderFields: [HTTPField] {
        [.init(name: .cookie, value: "test")]
    }

    /// A field section which the QPACK decoder cannot decode yet.
    ///
    /// It declares a required insert count of one and refers to that entry with a post-base index, but the entry
    /// only arrives with ``testUnblockingEncoderInstruction``. Until then the stream is blocked: RFC 9204 § 2.1.2.
    @available(anyAppleOS 26.0, *)
    private var testBlockedRequestPartialHeaderBytes: ByteBuffer {
        let fieldSection = FieldSection(
            prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 4096),
            lines: [.indexedWithPostBase(index: 0)]
        )
        var buffer = ByteBuffer()
        buffer.writeHTTP3PartialFrame(
            .headers(.init(fieldSection: fieldSection)),
            preferHuffmanEncoding: false
        )
        return buffer
    }

    /// The peer's encoder instruction which inserts the entry ``testBlockedRequestPartialHeaderBytes`` needs.
    private let testUnblockingEncoderInstruction = QPACKEncoderInstruction.insertWithLiteralName(
        name: "cookie",
        value: "test"
    )

    private let logger = Logger(label: "NIOHTTP3StreamHandlerTests")

    @available(anyAppleOS 26.0, *)
    @Test func receiveInvalidHeaders() throws {
        var errorReceived = false
        let qpackDelegate = TestQPACKConnectionDelegate(onConnectionError: { error in
            errorReceived = true
            #expect(error.code == .qpackDecoderError)
            #expect(error.h3ErrorCode == .qpackDecompressionFailed)
        })
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(connectionDelegate: qpackDelegate),
            delegate: TestDelegate(),
            logger: self.logger
        )
        let eventLoop = EmbeddedEventLoop()
        let recorderPromise = eventLoop.makePromise(of: [HTTP3Frame].self)
        let recorder = InboundDataRecorder(promise: recorderPromise, targetCount: 1)
        let channel = EmbeddedChannel(handlers: [handler, recorder], loop: eventLoop)

        // Read in a test header which the QPACK decoder will reject.
        try channel.writeInbound(self.testUndecodableRequestPartialHeaderBytes)

        expectH3Error(
            code: .qpackDecoderError,
            h3ErrorCode: .qpackDecompressionFailed,
            message: "Could not decode QPACK headers for stream 5"
        ) {
            _ = try recorderPromise.futureResult.wait()
        }
        #expect(errorReceived)
    }

    /// Receive headers which can't yet be decoded, but can be later.
    @available(anyAppleOS 26.0, *)
    @Test func receiveHeadersWhichNeedInstructions() throws {
        let eventLoop = EmbeddedEventLoop()
        // The coder writes its acknowledgements here once the decode goes through.
        let decoderStreamChannel = EmbeddedChannel()
        let qpackCoder = makeTestQPACKCoder(decoderStreamChannel: decoderStreamChannel)
        // The peer's encoder may use a dynamic table, but hasn't inserted anything into it yet.
        qpackCoder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))
        #expect(try decoderStreamChannel.readOutbound(as: ByteBuffer.self) == nil)

        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: qpackCoder,
            delegate: TestDelegate(),
            logger: self.logger
        )

        // Record events into a Deque so we can pop them as we expect them and assert nothing left at the end.
        let seenEvents = NIOLockedValueBox<Deque<DebugInboundEventsHandler.Event>>([])
        let eventRecorder = DebugInboundEventsHandler { event, _ in
            seenEvents.withLockedValue { $0.append(event) }
        }
        let channel = EmbeddedChannel(handlers: [handler, eventRecorder], loop: eventLoop)
        #expect(seenEvents.popFirst()?.isChannelRegistered == true)

        // Read in a header which references a dynamic table entry we have not been told about yet. The handler
        // must hold it back rather than forward a half-decoded frame.
        try channel.writeInbound(self.testBlockedRequestPartialHeaderBytes)
        #expect(seenEvents.isEmpty())

        // The missing entry arrives on the peer's encoder stream, which unblocks the decode.
        qpackCoder.receivedIncomingEncoderInstruction(self.testUnblockingEncoderInstruction)

        // Make sure we read the right value
        guard let readFrameAny = seenEvents.popFirst()?.readValue else {
            Issue.record("Expected to read a frame")
            return
        }
        // There's no API to unwrap a NIOAny ... unless you ask a handler to do it
        let readFrame = handler.unwrapOutboundIn(readFrameAny)
        #expect(readFrame == .headers(self.testBlockedRequestHeaderFields))
        // Make sure we also fired a readComplete
        #expect(seenEvents.popFirst()?.isChannelReadComplete == true)
        #expect(seenEvents.isEmpty())

        // The peer's encoder must learn that we took the entry, and that the field section using it was processed.
        let instructions = try decoderStreamChannel.readAllDecoderInstructions()
        #expect(instructions == [.insertCountIncrement(increment: 1), .sectionAcknowledgement(streamID: 5)])
    }

    @available(anyAppleOS 26.0, *)
    @Test func receiveUnknownFrameFollowedByHeaders() throws {
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(),
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

    @available(anyAppleOS 26.0, *)
    @Test func write() throws {
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .control, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(),
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
    @available(anyAppleOS 26.0, *)
    @Test func writeStreamError() throws {
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(),
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
    @available(anyAppleOS 26.0, *)
    @Test func writeConnectionError() throws {
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
//                decodeHeaders: { field, _ in
//                    Issue.record("Unexpected header decode \(field)")
//                }
            ),
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
    @available(anyAppleOS 26.0, *)
    @Test func writeAfterClose() throws {
        let eventLoop = EmbeddedEventLoop()
        let sawEOF = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
//                decodeHeaders: { field, _ in
//                    Issue.record("Unexpected header decode \(field)")
//                },
                onStreamClosed: { eof, _, _ in sawEOF.succeed(eof) }
            ),
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

    @available(anyAppleOS 26.0, *)
    @Test func connectionError() throws {
        let eventLoop = EmbeddedEventLoop()
        let connectionErrorPromise = eventLoop.makePromise(of: HTTP3Error.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .control, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .control,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
                onConnectionError: { connectionErrorPromise.succeed($0) }
            ),
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

    @available(anyAppleOS 26.0, *)
    @Test func channelInactive() throws {
        let eventLoop = EmbeddedEventLoop()
        // The bool is true if the close was clean, ie we saw EOF
        let streamClosedPromise = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .control, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .control,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
                onStreamClosed: { eof, _, _ in streamClosedPromise.succeed(eof) },
            ),
            logger: self.logger
        )
        let channel = EmbeddedChannel(handlers: [handler], loop: eventLoop)
        #expect(try channel.finish().isClean)
        let sawEOF = try streamClosedPromise.futureResult.wait()
        #expect(sawEOF == false)
    }

    @available(anyAppleOS 26.0, *)
    @Test func channelInactiveAfterEOF() throws {
        let eventLoop = EmbeddedEventLoop()
        // The bool is true if the close was clean, ie we saw EOF
        let streamClosedPromise = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .control, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .control,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
                onStreamClosed: { eof, _, _ in streamClosedPromise.succeed(eof) },
            ),
            logger: self.logger
        )
        let channel = EmbeddedChannel(handlers: [handler], loop: eventLoop)
        // We fire an input closed, which means the bool will be true this time, unlike the test above.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        #expect(try channel.finish().isClean)
        let sawEOF = try streamClosedPromise.futureResult.wait()
        #expect(sawEOF == true)
    }

    @available(anyAppleOS 26.0, *)
    @Test func channelInactiveAfterEOFWaitingForDecode() throws {
        let eventLoop = EmbeddedEventLoop()
        // The bool is true if the close was clean, ie we saw EOF
        let streamClosedPromise = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
                onStreamClosed: { eof, _, _ in streamClosedPromise.succeed(eof) },
            ),
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
        try channel.writeInbound(self.testBlockedRequestPartialHeaderBytes)

        // Close the input
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Close
        #expect(try channel.finish().isClean)
        let sawEOF = try streamClosedPromise.futureResult.wait()
        #expect(sawEOF == false)
    }

    // Make sure that if we have buffered data which we didn't fire read for, then we do so before forwarding channel inactive.
    @available(anyAppleOS 26.0, *)
    @Test func flushBuffersWhenChannelInactive() throws {
        let eventLoop = EmbeddedEventLoop()
        // The bool is true if the close was clean, ie we saw EOF
        let streamClosedPromise = eventLoop.makePromise(of: Bool.self)
        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
                onStreamClosed: { eof, _, _ in streamClosedPromise.succeed(eof) },
            ),
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

    @available(anyAppleOS 26.0, *)
    @Test func testMoreInputAfterInputClosed() throws {
        let eventLoop = EmbeddedEventLoop()

        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
                onStreamClosed: { _, _, _ in },
            ),
            logger: self.logger
        )
        let recorderPromise = eventLoop.makePromise(of: [HTTP3Frame].self)
        let recorder = InboundDataRecorder(promise: recorderPromise, targetCount: 2)
        let channel = EmbeddedChannel(handlers: [handler, recorder], loop: eventLoop)

        // Headers frame
        try channel.writeInbound(self.testRequestPartialHeaderBytes)
//        handler.onQPACKDecodeResult(fields: self.testRequestHeaderFields)

        // Input close
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        try handler.channelReadComplete(context: channel.pipeline.syncOperations.context(handler: handler))

        // Data frame
        try channel.writeInbound(ByteBuffer(bytes: [0, 4, 1, 2, 3, 4]))

        // We only see the headers frame, not the data
        let seenFrames = recorder.getDataOnEventloop()
        #expect(seenFrames.count == 1)
    }

    @available(anyAppleOS 26.0, *)
    @Test func inputClosedWithIncompleteRequest() throws {
        let eventLoop = EmbeddedEventLoop()

        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: true, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
                onStreamClosed: { _, _, _ in },
            ),
            logger: self.logger
        )

        let inboundEvents = NIOLockedValueBox<[DebugInboundEventsHandler.Event]>([])
        let inboundEventRecorder = DebugInboundEventsHandler { event, _ in
            inboundEvents.withLockedValue { $0.append(event) }
        }

        let outboundEvents = NIOLockedValueBox<[DebugOutboundEventsHandler.Event]>([])
        let outboundEventRecorder = DebugOutboundEventsHandler { event, _ in
            outboundEvents.withLockedValue { $0.append(event) }
        }

        let channel = EmbeddedChannel(
            handlers: [outboundEventRecorder, handler, inboundEventRecorder],
            loop: eventLoop
        )

        // Close the input before having received a complete request.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        try handler.channelReadComplete(context: channel.pipeline.syncOperations.context(handler: handler))

        let recordedInboundEvents = inboundEvents.withLockedValue { $0 }
        let recordedOutboundEvents = outboundEvents.withLockedValue { $0 }

        try #require(recordedInboundEvents.count == 3)
        #expect(recordedInboundEvents[0].isChannelRegistered)
        let error = try #require(recordedInboundEvents[1].isHTTP3Error)
        #expect(error.code == .peerTerminatedInboundStream)
        #expect(error.h3ErrorCode == .requestIncomplete)
        #expect(recordedInboundEvents[2].isInputClosedEvent)

        try #require(recordedOutboundEvents.count == 2)
        #expect(recordedOutboundEvents[0].isChannelRegistered)
        let resetStreamEvent = try #require(recordedOutboundEvents[1].isResetStreamEvent)
        #expect(resetStreamEvent.code == QUICApplicationErrorCode(HTTP3ErrorCode.requestIncomplete))
    }

    @available(anyAppleOS 26.0, *)
    @Test func inputClosedWithIncompleteResponse() throws {
        let eventLoop = EmbeddedEventLoop()

        let handler = HTTP3StreamHandler(
            stateMachine: .init(streamType: .request, incoming: false, preferHuffmanEncoding: false),
            streamID: 5,
            streamType: .request,
            qpackCoder: makeTestQPACKCoder(),
            delegate: TestDelegate(
                onStreamClosed: { _, _, _ in },
            ),
            logger: self.logger
        )

        let inboundEvents = NIOLockedValueBox<[DebugInboundEventsHandler.Event]>([])
        let inboundEventRecorder = DebugInboundEventsHandler { event, _ in
            inboundEvents.withLockedValue { $0.append(event) }
        }
        let channel = EmbeddedChannel(handlers: [handler, inboundEventRecorder], loop: eventLoop)

        // Close the input before having received a complete request.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        try handler.channelReadComplete(context: channel.pipeline.syncOperations.context(handler: handler))

        let recordedInboundEvents = inboundEvents.withLockedValue { $0 }

        try #require(recordedInboundEvents.count == 3)
        #expect(recordedInboundEvents[0].isChannelRegistered)
        let error = try #require(recordedInboundEvents[1].isHTTP3Error)
        #expect(error.code == .peerTerminatedInboundStream)
        #expect(recordedInboundEvents[2].isInputClosedEvent)
    }
}

extension DebugInboundEventsHandler.Event {
    var isInputClosedEvent: Bool {
        switch self {
        case .userInboundEventTriggered(let event as ChannelEvent):
            return event == .inputClosed

        default:
            return false
        }
    }

    var isHTTP3Error: HTTP3Error? {
        switch self {
        case .errorCaught(let error as HTTP3Error):
            return error

        default:
            return nil
        }
    }
}

extension DebugOutboundEventsHandler.Event {
    var isChannelRegistered: Bool {
        switch self {
        case .register:
            return true

        default:
            return false
        }
    }

    var isResetStreamEvent: NIOQUICHelpers.QUICResetStreamEvent? {
        switch self {
        case .triggerUserOutboundEvent(let event as NIOQUICHelpers.QUICResetStreamEvent):
            return event

        default:
            return nil
        }
    }
}
