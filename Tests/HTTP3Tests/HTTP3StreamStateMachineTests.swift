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
import NIOCore
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK
import Testing

@_spi(PackageInternal) @testable import HTTP3

/// Tests for ``HTTP3StreamStateMachine``.
///
/// The state machine no longer owns a frame decoder: frames are pushed into it one at a time, the way
/// `HTTP3StreamHandler` does after `NIOSingleStepByteToMessageProcessor` has produced them. So these tests drive it
/// with already-decoded ``HTTP3PartialFrame``s. Byte-level decoding is covered by `HTTP3FrameDecoderTests`.
struct HTTP3StreamStateMachineTests {
    private let testDataFrame = HTTP3Frame.data(.init(bytes: [1, 2, 3, 4]))
    private let testPartialDataFrame = HTTP3PartialFrame.data(.init(bytes: [1, 2, 3, 4]))

    private let testSettings = HTTP3Settings(
        qpackMaximumTableCapacity: 151_288_809_941_952_652,
        qpackBlockedStreams: 1,
        h3Datagram: false
    )

    private var testRequestHeaderFields: [HTTPField] {
        [
            .init(name: .method, value: "GET"),
            .init(name: .path, value: "/"),
            .init(name: .authority, value: "test"),
            .init(name: .scheme, value: "http"),
        ]
    }

    private var testResponseHeaderFields: [HTTPField] {
        [
            .init(name: .status, value: "200")
        ]
    }

    private var testTrailerFields: [HTTPField] {
        [
            .init(name: .init("test")!, value: "test")
        ]
    }

    private var testRequestHeader: HTTP3PartialFrame.Headers {
        .init(fieldSection: StaticQPACKEncoder().encode(headers: self.testRequestHeaderFields))
    }

    private var testResponseHeader: HTTP3PartialFrame.Headers {
        .init(fieldSection: StaticQPACKEncoder().encode(headers: self.testResponseHeaderFields))
    }

    private var testTrailer: HTTP3PartialFrame.Headers {
        .init(fieldSection: StaticQPACKEncoder().encode(headers: self.testTrailerFields))
    }

    /// These bytes encode `testResponseHeader`.
    private var testResponseHeaderFrameBytes: [UInt8] {
        .init(buffer: ByteBuffer(frame: .headers(self.testResponseHeader)))
    }

    /// These bytes encode `testDataFrame`.
    private let testDataFrameBytes: [UInt8] = [0, 4, 1, 2, 3, 4]

    private func testQpackDecoderClosure() -> (HTTP3PartialFrame.Headers) -> QPACKFullDecodeResult {
        var qpackDecoder = QPACKDecoder(
            dynamicTableMaxCapacity: 0
        )
        return { partialHeader in
            guard let prefix = qpackDecoder.decodeFieldSectionPrefix(partialHeader.fieldSection.prefix) else {
                return .error(QPACKDecoderError.invalidFieldSection)
            }
            return qpackDecoder.decodeFieldSection(
                prefix: prefix,
                lines: partialHeader.fieldSection.lines,
                streamID: 1
            )
        }
    }

    @Test
    func testNothing() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        let waiting = machine.isWaitingForHeaderDecode
        #expect(!waiting)
        let readyToDecode = machine.readyToDecode(ByteBuffer())
        #expect(readyToDecode)
        let readCompleted = machine.readCompleted()
        #expect(readCompleted)
    }

    @Test
    func testReadFrame() {
        var machine = HTTP3StreamStateMachine(streamType: .control, incoming: true, preferHuffmanEncoding: false)
        machine.assertReturnFrame(.settings(self.testSettings), expected: .settings(self.testSettings))
    }

    @Test
    func testDroppedFrameFollowedByNormal() {
        let decode = self.testQpackDecoderClosure()
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        // Unknown frames are dropped without any further action.
        let action = machine.decodedUnknownFrame()
        guard case .doNothing = action else {
            Issue.record("Unexpected action \(action)")
            return
        }

        machine.assertReceivedHeaders(self.testRequestHeader, decode: decode)
        machine.assertReturnFrame(self.testPartialDataFrame, expected: self.testDataFrame)
    }

    @Test
    func testQPACK() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        let action1 = machine.decodedFrame(.headers(self.testRequestHeader))
        guard case .decodeHeader(let partialHeader) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        // The header we've been asked to decode should match the one we put in
        #expect(partialHeader == self.testRequestHeader)
        // Nothing else can be processed until we hand back a result.
        let waiting = machine.isWaitingForHeaderDecode
        #expect(waiting)

        let decodeResult = self.testRequestHeaderFields
        guard let action2 = machine.gotHeaderDecodeResult(decodeResult) else {
            Issue.record("Expected an action")
            return
        }
        guard case .returnFrame(let frame) = action2.frameAction else {
            Issue.record("Unexpected action \(action2.frameAction)")
            return
        }
        #expect(frame == .headers(decodeResult))
        #expect(drain(action2.takeNextActions()).isEmpty)
        let stillWaiting = machine.isWaitingForHeaderDecode
        #expect(!stillWaiting)
    }

    @Test
    func testLotsOfQPACK() {
        let decode = self.testQpackDecoderClosure()
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        machine.assertReceivedHeaders(self.testRequestHeader, decode: decode)
        machine.assertReceivedHeaders(self.testTrailer, decode: decode)
    }

    /// Everything which arrives whilst a header section is being decoded must be queued behind it.
    @Test
    func testQPACKQueueing() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        let action1 = machine.decodedFrame(.headers(self.testRequestHeader))
        guard case .decodeHeader(let partialHeader) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        #expect(partialHeader == self.testRequestHeader)

        // Everything which arrives from here on has to wait.
        let dataBytes = ByteBuffer(bytes: self.testDataFrameBytes)
        let decodeQueued1 = machine.readyToDecode(dataBytes)
        #expect(!decodeQueued1)
        let readCompleteQueued = machine.readCompleted()
        #expect(!readCompleteQueued)
        let decodeQueued2 = machine.readyToDecode(dataBytes)
        #expect(!decodeQueued2)

        // Put in the decode result
        let decodeResult = self.testRequestHeaderFields
        guard let action2 = machine.gotHeaderDecodeResult(decodeResult) else {
            Issue.record("Expected an action")
            return
        }
        guard case .returnFrame(let frame) = action2.frameAction else {
            Issue.record("Unexpected action \(action2.frameAction)")
            return
        }
        #expect(frame == .headers(decodeResult))

        // We get everything back, in the order it arrived.
        #expect(
            drain(action2.takeNextActions()) == [
                .decodeFrames(dataBytes),
                .fireReadComplete,
                .decodeFrames(dataBytes),
            ]
        )

        // And we're unblocked again.
        let stillWaiting = machine.isWaitingForHeaderDecode
        #expect(!stillWaiting)
        let readyAgain = machine.readyToDecode(dataBytes)
        #expect(readyAgain)
        machine.assertReturnFrame(self.testPartialDataFrame, expected: self.testDataFrame)
    }

    /// Actions which couldn't be replayed because we blocked on another decode get queued behind the new decode.
    @Test
    func testQPACKRequeueing() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        // A request head, followed by trailers which we'll block on again.
        guard case .decodeHeader = machine.decodedFrame(.headers(self.testRequestHeader)) else {
            Issue.record("Unexpected action")
            return
        }
        let readCompleteQueued = machine.readCompleted()
        #expect(!readCompleteQueued)
        guard let action1 = machine.gotHeaderDecodeResult(self.testRequestHeaderFields) else {
            Issue.record("Expected an action")
            return
        }
        let pending = action1.takeNextActions()

        // Whilst replaying, we hit the trailers and block again. The rest of the replay is handed back to us.
        guard case .decodeHeader = machine.decodedFrame(.headers(self.testTrailer)) else {
            Issue.record("Unexpected action")
            return
        }
        machine.enqueue(pending)

        guard let action2 = machine.gotHeaderDecodeResult(self.testTrailerFields) else {
            Issue.record("Expected an action")
            return
        }
        #expect(drain(action2.takeNextActions()) == [.fireReadComplete])
    }

    @Test
    func testQPACKError() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        // Machine should ask us to decode a header now
        let action1 = machine.decodedFrame(.headers(self.testRequestHeader))
        guard case .decodeHeader(let partialHeader) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        #expect(partialHeader == self.testRequestHeader)

        // We tell it we got an error
        let testError = HTTP3Error(
            code: .qpackDecoderError,
            message: "test",
            cause: nil,
            errorCode: .internalError,
            location: .here()
        )
        guard let failure = machine.gotHeaderDecodeError(testError) else {
            Issue.record("Expected an action")
            return
        }
        expectH3ErrorEqual(
            error: failure.error,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .internalError,
            expectedMessage: "test"
        )

        // Further bytes are dropped because they come after an error
        let readyToDecode = machine.readyToDecode(.init(bytes: self.testDataFrameBytes))
        #expect(!readyToDecode)

        // Writes also ignored due to that error
        let writeAction = machine.writeFrame(frame: .headers(self.testResponseHeaderFields))
        #expect(writeAction.isPreviousError)

        // A second decode result is ignored: we're already in an error state.
        let secondFailure = machine.gotHeaderDecodeError(testError)
        #expect(secondFailure == nil)
    }

    /// Read bytes which do not form a valid frame. The frame decoder rejects those; the state machine is told about it.
    @Test
    func testReadBadFrame() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        let decodeError = HTTP3Error(
            code: .forbiddenFrameType,
            message: "Forbidden frame type",
            cause: nil,
            errorCode: .frameUnexpected,
            location: .here()
        )
        let action1 = machine.frameDecodeError(decodeError)
        guard case .emitConnectionError(let error) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        expectH3ErrorEqual(error: error, expectedCode: .forbiddenFrameType, expectedH3ErrorCode: .frameUnexpected)

        // All further reads and writes should fail
        let readyToDecode = machine.readyToDecode(.init(bytes: self.testDataFrameBytes))
        #expect(!readyToDecode)
        let writeAction = machine.writeFrame(frame: .headers(self.testResponseHeaderFields))
        #expect(writeAction.isPreviousError)

        // The error is only reported once.
        guard case .previousError = machine.frameDecodeError(decodeError) else {
            Issue.record("Expected a previousError action")
            return
        }
    }

    /// Read a valid frame, but of a type which isn't currently valid.
    /// We'll be sending a data frame when we need headers.
    @Test
    func testReadInvalidFrame() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        let action1 = machine.decodedFrame(self.testPartialDataFrame)
        guard case .emitConnectionError(let error) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        expectH3ErrorEqual(error: error, expectedCode: .unexpectedFrame, expectedH3ErrorCode: .frameUnexpected)

        // All further reads and writes should fail
        let readyToDecode = machine.readyToDecode(.init(bytes: self.testDataFrameBytes))
        #expect(!readyToDecode)
        let writeAction = machine.writeFrame(frame: .headers(self.testResponseHeaderFields))
        #expect(writeAction.isPreviousError)
    }

    @Test
    func testRoundtrip() throws {
        let decode = self.testQpackDecoderClosure()

        var server = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        var client = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)

        // Client writes a head + data
        let clientWrite1 = client.writeFrameAndQPACK(frame: .headers(self.testRequestHeaderFields))
        let clientWrite2 = client.writeFrameAndQPACK(frame: .data(.init(bytes: [1, 2, 3])))

        // Server receives
        server.assertReceivedHeaders(try clientWrite1.decodedHeaders(), decode: decode)
        server.assertReturnFrame(try clientWrite2.decodedFrame(), expected: .data(.init(bytes: [1, 2, 3])))

        // Server writes a head + data
        let serverWrite1 = server.writeFrameAndQPACK(frame: .headers(self.testResponseHeaderFields))
        let serverWrite2 = server.writeFrameAndQPACK(frame: .data(.init(bytes: [4, 5, 6])))

        // Client receives
        client.assertReceivedHeaders(try serverWrite1.decodedHeaders(), decode: decode)
        client.assertReturnFrame(try serverWrite2.decodedFrame(), expected: .data(.init(bytes: [4, 5, 6])))
    }

    @Test
    func testDoubleResponse() throws {
        let decode = self.testQpackDecoderClosure()

        var server = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        var client = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)

        // Client writes a head + data
        let clientWrite1 = client.writeFrameAndQPACK(frame: .headers(self.testRequestHeaderFields))
        let clientWrite2 = client.writeFrameAndQPACK(frame: .data(.init(bytes: [1, 2, 3])))

        // Server receives
        server.assertReceivedHeaders(try clientWrite1.decodedHeaders(), decode: decode)
        server.assertReturnFrame(try clientWrite2.decodedFrame(), expected: .data(.init(bytes: [1, 2, 3])))

        // Server writes a double head + data
        let serverWrite1 = server.writeFrameAndQPACK(frame: .headers([.init(name: .status, value: "100")]))
        let serverWrite2 = server.writeFrameAndQPACK(frame: .headers(self.testResponseHeaderFields))
        let serverWrite3 = server.writeFrameAndQPACK(frame: .data(.init(bytes: [4, 5, 6])))

        // Client receives
        client.assertReceivedHeaders(try serverWrite1.decodedHeaders(), decode: decode)
        client.assertReceivedHeaders(try serverWrite2.decodedHeaders(), decode: decode)
        client.assertReturnFrame(try serverWrite3.decodedFrame(), expected: .data(.init(bytes: [4, 5, 6])))
    }

    @Test
    func testWriteDuringIncomingData() {
        let decode = self.testQpackDecoderClosure()

        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        // Read request headers and some data
        machine.assertReceivedHeaders(self.testRequestHeader, decode: decode)
        machine.assertReturnFrame(self.testPartialDataFrame, expected: self.testDataFrame)

        // We can send response headers, even though the request body is still arriving
        let writeAction = machine.writeFrameAndQPACK(frame: .headers(self.testResponseHeaderFields))
        writeAction?.assertReturnBytes(expectedBytes: .init(bytes: self.testResponseHeaderFrameBytes))
    }

    @Test
    func testWriteDuringIncomingTrailers() {
        let decode = self.testQpackDecoderClosure()

        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        // Read request headers
        machine.assertReceivedHeaders(self.testRequestHeader, decode: decode)

        // Read request trailers, but don't decode them yet
        guard case .decodeHeader = machine.decodedFrame(.headers(self.testTrailer)) else {
            Issue.record("Unexpected action")
            return
        }

        // We can write response headers, even though we're in the middle of processing incoming request trailers
        let writeAction1 = machine.writeFrameAndQPACK(frame: .headers(self.testResponseHeaderFields))
        writeAction1?.assertReturnBytes(expectedBytes: .init(bytes: self.testResponseHeaderFrameBytes))

        // Now decode the request trailers
        let testResult = self.testTrailerFields
        guard let action = machine.gotHeaderDecodeResult(testResult) else {
            Issue.record("Expected an action")
            return
        }
        guard case .returnFrame(let frame) = action.frameAction else {
            Issue.record("Unexpected action \(action.frameAction)")
            return
        }
        #expect(frame == .headers(testResult))

        // We can still write data out
        let writeAction2 = machine.writeFrameAndQPACK(frame: self.testDataFrame)
        writeAction2?.assertReturnBytes(expectedBytes: .init(bytes: self.testDataFrameBytes))
    }

    @Test
    func testWriteEncodeOutOfSequence() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)

        // Write request DATA (before headers). This is an error
        let action = machine.writeFrame(frame: .data(.init()))
        switch action {
        case .wouldBeConnectionError(let error):
            expectH3Error(
                code: .unexpectedFrame,
                h3ErrorCode: .frameUnexpected,
                message: "Expected headers, got data"
            ) {
                throw error
            }
        default:
            Issue.record("Unexpected action \(action)")
        }
    }

    @Test
    func testWriteDoubleData() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)
        let action1 = machine.writeFrameAndQPACK(frame: .headers(self.testRequestHeaderFields))
        action1?.assertReturnBytes(
            expectedBytes: ByteBuffer(
                frame: .headers(.init(fieldSection: StaticQPACKEncoder().encode(headers: self.testRequestHeaderFields)))
            )
        )

        let action2 = machine.writeFrameAndQPACK(frame: .data(.init(bytes: [1, 2, 3])))
        action2?.assertReturnBytes(expectedBytes: .init(bytes: [0, 3, 1, 2, 3]))

        let action3 = machine.writeFrameAndQPACK(frame: .data(.init(bytes: [4, 5, 6])))
        action3?.assertReturnBytes(expectedBytes: .init(bytes: [0, 3, 4, 5, 6]))
    }

    // MARK: Input closed

    @Test
    func testInputClosedBeforeReceivingCompleteRequest() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        let action = machine.inputClosed()
        guard case .resetStream(let error) = action else {
            Issue.record("Unexpected action \(String(describing: action))")
            return
        }

        expectH3ErrorEqual(
            error: error,
            expectedCode: .peerTerminatedInboundStream,
            expectedH3ErrorCode: .requestIncomplete
        )
    }

    @Test
    func testInputClosedBeforeReceivingCompleteResponse() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)
        let action = machine.inputClosed()

        guard case .emitErrorAndEvent(let error) = action else {
            Issue.record("Unexpected action \(String(describing: action))")
            return
        }

        expectH3ErrorEqual(error: error, expectedCode: .peerTerminatedInboundStream, expectedH3ErrorCode: nil)
    }

    @Test
    func testInputClosedAfterReceivingCompleteRequest() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        let action1 = machine.decodedFrame(.headers(self.testRequestHeader))
        guard case .decodeHeader(let headerToDecode) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        #expect(headerToDecode.fieldSection.lines.count == 4)

        _ = machine.gotHeaderDecodeResult(self.testRequestHeaderFields)

        // If the input closed after receiving a complete request, the state machine should just tell us to fire the
        // inputClosed event.
        guard case .emitEvent = machine.inputClosed() else {
            Issue.record("Unexpected action")
            return
        }
    }

    @Test
    func testInputClosedAfterReceivingCompleteResponse() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)

        // Before simulating receiving a response, we must send a request.
        _ = machine.writeFrame(frame: .headers(self.testRequestHeaderFields))

        let action1 = machine.decodedFrame(.headers(self.testResponseHeader))
        guard case .decodeHeader(let headerToDecode) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        #expect(headerToDecode.fieldSection.lines.count == 1)

        _ = machine.gotHeaderDecodeResult(self.testResponseHeaderFields)

        guard case .emitEvent = machine.inputClosed() else {
            Issue.record("Unexpected action")
            return
        }
    }

    /// The input close must not overtake a header section which is still being decoded.
    @Test
    func testInputClosedCantOvertakeQueuedFrame() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        let action1 = machine.decodedFrame(.headers(self.testRequestHeader))
        guard case .decodeHeader(let headerToDecode) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        #expect(headerToDecode.fieldSection.lines.count == 4)

        // There is no action for the input close yet, it just gets queued.
        let queuedClose = machine.inputClosed()
        #expect(queuedClose == nil)

        guard let action2 = machine.gotHeaderDecodeResult(self.testRequestHeaderFields) else {
            Issue.record("Expected an action")
            return
        }
        guard case .returnFrame(let frame) = action2.frameAction else {
            Issue.record("Unexpected action \(action2.frameAction)")
            return
        }
        #expect(frame == .headers(self.testRequestHeaderFields))

        // The EOF comes back to us behind the header, and only now produces an action.
        #expect(drain(action2.takeNextActions()) == [.eof])
        guard case .emitEvent = machine.inputClosed() else {
            Issue.record("Unexpected action")
            return
        }
    }

    // MARK: Stream closed

    @Test
    func testStreamClosed() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        let action = machine.closed()
        #expect(action == .streamClosed(seenEOF: false))
    }

    @Test
    func testStreamClosedAfterError() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        let action1 = machine.streamErrorCaught(errorCode: QUICApplicationErrorCode(.messageError))
        #expect(action1 != nil)

        let action2 = machine.closed()
        #expect(action2 == .streamClosed(seenEOF: false))
    }

    /// If we blocked on a QPACK decode we never surfaced the queued EOF, so this is an unclean close.
    @Test
    func testStreamClosedWhilstWaitingForDecode() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        guard case .decodeHeader = machine.decodedFrame(.headers(self.testRequestHeader)) else {
            Issue.record("Unexpected action")
            return
        }
        let queuedClose = machine.inputClosed()
        #expect(queuedClose == nil)

        let action = machine.closed()
        #expect(action == .streamClosed(seenEOF: false))
    }

    @Test
    func testStreamClosedAfterEOF() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        // A request stream which is closed before a complete request resets, and that's an error state.
        // Use a control stream so that the EOF is clean.
        var control = HTTP3StreamStateMachine(streamType: .control, incoming: true, preferHuffmanEncoding: false)
        control.assertReturnFrame(.settings(self.testSettings), expected: .settings(self.testSettings))
        _ = control.inputClosed()
        let controlClose = control.closed()
        #expect(controlClose == .streamClosed(seenEOF: true))

        // For the request stream, the EOF was still seen even though it produced a reset.
        _ = machine.inputClosed()
        let machineClose = machine.closed()
        #expect(machineClose == .streamClosed(seenEOF: true))
    }

    @Test
    func testWriteFailsAfterStreamClosed() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)
        let action = machine.closed()
        #expect(action == .streamClosed(seenEOF: false))

        let action2 = machine.writeFrame(frame: .headers(self.testRequestHeaderFields))
        guard case .alreadyClosed = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }
    }

    @Test
    func testStreamClosedDuringQPACKEncode() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)

        let action1 = machine.writeFrame(frame: .headers(self.testRequestHeaderFields))
        guard case .encodeHeaders(let fieldsToEncode) = action1 else {
            Issue.record("Unexpected action \(String(describing: action1))")
            return
        }
        #expect(fieldsToEncode == self.testRequestHeaderFields)

        // Now close before giving the result back
        let action2 = machine.closed()
        #expect(action2 == .streamClosed(seenEOF: false))

        // Now give the encode result
        let action3 = machine.gotHeaderEncodeResult(self.testRequestHeader, from: fieldsToEncode)
        guard case .alreadyClosed = action3 else {
            Issue.record("Unexpected action \(String(describing: action3))")
            return
        }
    }

    @Test
    func testPushPromise() {
        // A push promise is normally valid on a request stream, but we don't allow it because we don't implement push
        // This means we never send a max push id, so it is a protocol error for the remote to send us a push promise
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)
        // Before simulating receiving a response, we must send a request
        _ = machine.writeFrame(frame: .headers(self.testRequestHeaderFields))

        let testFieldSection = FieldSection(
            prefix: .init(
                encodedRequiredInsertCount: 0,
                deltaBase: 0,
                signBit: false
            ),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )

        let action = machine.decodedFrame(.pushPromise(.init(pushID: 1, fieldSection: testFieldSection)))
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        expectH3ErrorEqual(error: error, expectedCode: .unexpectedFrame, expectedH3ErrorCode: .idError)
    }

    @Test
    func testInputAfterInputClosed() {
        var machine = HTTP3StreamStateMachine(streamType: .control, incoming: true, preferHuffmanEncoding: false)
        guard case .emitEvent = machine.inputClosed() else {
            Issue.record("Unexpected action")
            return
        }
        // Any bytes which arrive after the close are dropped.
        let readyToDecode = machine.readyToDecode(.init(bytes: [0x04, 0x00]))
        #expect(!readyToDecode)
        // And so is any frame which somehow still reaches us.
        guard case .alreadyClosed = machine.decodedFrame(.settings(self.testSettings)) else {
            Issue.record("Unexpected action")
            return
        }
    }
}

extension HTTP3StreamStateMachine {
    /// Push in `frame` and assert that it comes straight back out as `expected`.
    fileprivate mutating func assertReturnFrame(
        _ frame: HTTP3PartialFrame,
        expected: HTTP3Frame,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let next = self.decodedFrame(frame)
        switch next {
        case .returnFrame(let frame):
            #expect(frame == expected, sourceLocation: sourceLocation)
        default:
            Issue.record("Unexpected action \(next)", sourceLocation: sourceLocation)
        }
    }

    /// Push in a header section, run it through `decode`, and assert the resulting frame comes back out.
    fileprivate mutating func assertReceivedHeaders(
        _ header: HTTP3PartialFrame.Headers,
        decode: (HTTP3PartialFrame.Headers) -> QPACKFullDecodeResult,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let next = self.decodedFrame(.headers(header))
        guard case .decodeHeader(let partialHeader) = next else {
            Issue.record("Unexpected action \(next)", sourceLocation: sourceLocation)
            return
        }
        let waiting = self.isWaitingForHeaderDecode
        #expect(waiting, sourceLocation: sourceLocation)

        switch decode(partialHeader) {
        case .missingInsertCount:
            Issue.record("Unexpected result", sourceLocation: sourceLocation)
        case .success(let fields, _):
            guard let action = self.gotHeaderDecodeResult(fields) else {
                Issue.record("Expected an action", sourceLocation: sourceLocation)
                return
            }
            guard case .returnFrame(let frame) = action.frameAction else {
                Issue.record("Unexpected action \(action.frameAction)", sourceLocation: sourceLocation)
                return
            }
            #expect(frame == .headers(fields), sourceLocation: sourceLocation)
            #expect(drain(action.takeNextActions()).isEmpty, sourceLocation: sourceLocation)
        case .error(let qpackError):
            let error = HTTP3Error(
                code: .qpackDecoderError,
                message: "Failed to qpack decode",
                cause: qpackError,
                errorCode: .qpackDecompressionFailed,
                location: .here()
            )
            _ = self.gotHeaderDecodeError(error)
        }
    }
}

extension HTTP3StreamStateMachine.ResolvedAction {
    fileprivate func assertReturnBytes(expectedBytes: ByteBuffer, sourceLocation: SourceLocation = #_sourceLocation) {
        switch self {
        case .returnBytes(let bytes):
            #expect(
                bytes == expectedBytes,
                sourceLocation: sourceLocation
            )
        default:
            Issue.record("Unexpected action \(self)", sourceLocation: sourceLocation)
        }
    }

    /// Decode the bytes this write produced back into the single frame they encode.
    fileprivate func decodedFrame(sourceLocation: SourceLocation = #_sourceLocation) throws -> HTTP3PartialFrame {
        guard case .returnBytes(var bytes) = self else {
            throw UnexpectedWriteAction(description: "\(self)")
        }
        var decoder = HTTP3FrameDecoder()
        guard case .known(let frame)? = try decoder.decode(buffer: &bytes) else {
            throw UnexpectedWriteAction(description: "Didn't decode a known frame")
        }
        #expect(bytes.readableBytes == 0, sourceLocation: sourceLocation)
        return frame
    }

    /// The same as ``decodedFrame(sourceLocation:)``, but for a write which encoded a header section.
    fileprivate func decodedHeaders(
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> HTTP3PartialFrame.Headers {
        guard case .headers(let headers) = try self.decodedFrame(sourceLocation: sourceLocation) else {
            throw UnexpectedWriteAction(description: "Not a headers frame")
        }
        return headers
    }
}

private struct UnexpectedWriteAction: Error {
    var description: String
}

extension HTTP3StreamStateMachine.WriteFrameAction {
    var isPreviousError: Bool {
        switch self {
        case .previousError:
            return true
        default:
            return false
        }
    }
}

extension HTTP3StreamStateMachine {
    /// Test convenience: write a frame using a throwaway buffer, for assertions that don't inspect bytes.
    fileprivate mutating func writeFrame(frame: HTTP3Frame) -> WriteFrameAction {
        var buffer = ByteBuffer()
        return self.writeFrame(frame: frame, into: &buffer)
    }

    /// Test convenience: deliver an encode result using a throwaway buffer.
    fileprivate mutating func gotHeaderEncodeResult(
        _ result: HTTP3PartialFrame.Headers,
        from: [HTTPField]
    ) -> HeaderEncodeResultAction {
        var buffer = ByteBuffer()
        return self.gotHeaderEncodeResult(result, from: from, into: &buffer)
    }

    fileprivate enum ResolvedAction {
        case returnBytes(ByteBuffer)
        case wouldBeStreamError(HTTP3Error)
        case wouldBeConnectionError(HTTP3Error)
        case alreadyClosed
    }

    /// Do a write, and do the qpack too, and return just one action.
    fileprivate mutating func writeFrameAndQPACK(frame: HTTP3Frame) -> ResolvedAction? {
        let encoder = StaticQPACKEncoder()
        var buffer = ByteBuffer()
        let action = self.writeFrame(frame: frame, into: &buffer)
        switch action {
        case .previousError:
            return nil
        case .wroteBytes:
            return .returnBytes(buffer)
        case .wouldBeStreamError(let error):
            return .wouldBeStreamError(error)
        case .wouldBeConnectionError(let error):
            return .wouldBeConnectionError(error)
        case .alreadyClosed:
            return .alreadyClosed
        case .encodeHeaders(let fields):
            let qpackResult = encoder.encode(headers: fields)
            let action2 = self.gotHeaderEncodeResult(.init(fieldSection: qpackResult), from: fields, into: &buffer)
            switch action2 {
            case .wroteBytes:
                return .returnBytes(buffer)
            case .previousError:
                return nil
            case .alreadyClosed:
                return nil
            }
        }
    }
}

extension Optional where Wrapped == HTTP3StreamStateMachine.ResolvedAction {
    fileprivate func decodedFrame(sourceLocation: SourceLocation = #_sourceLocation) throws -> HTTP3PartialFrame {
        guard let self else {
            throw UnexpectedWriteAction(description: "No write action at all")
        }
        return try self.decodedFrame(sourceLocation: sourceLocation)
    }

    fileprivate func decodedHeaders(
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> HTTP3PartialFrame.Headers {
        guard let self else {
            throw UnexpectedWriteAction(description: "No write action at all")
        }
        return try self.decodedHeaders(sourceLocation: sourceLocation)
    }
}

extension ByteBuffer {
    /// Create a buffer and write a single frame into it.
    fileprivate init(frame: HTTP3PartialFrame) {
        self.init()
        self.writeHTTP3PartialFrame(frame, preferHuffmanEncoding: false)
    }
}

/// Drain a noncopyable deque into an array.
///
/// ``UniqueDeque`` is neither a `Sequence` nor `Equatable`, and `#expect` needs a `Copyable` argument, so pending
/// actions have to be materialised before they can be asserted on.
private func drain(
    _ actions: consuming UniqueDeque<HTTP3StreamStateMachine.PendingReadAction>
) -> [HTTP3StreamStateMachine.PendingReadAction] {
    var actions = actions
    var result: [HTTP3StreamStateMachine.PendingReadAction] = []
    while let action = actions.popFirst() {
        result.append(action)
    }
    return result
}
