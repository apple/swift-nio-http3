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
import HTTPTypes
import NIOCore
import NIOQUICHelpers
import QPACK
import Testing

struct HTTP3StreamStateMachineTests {
    private let testDataFrame = HTTP3Frame.data(.init(bytes: [1, 2, 3, 4]))

    /// These bytes encode `testDataFrame`.
    private let testDataFrameBytes: [UInt8] = [0, 4, 1, 2, 3, 4]

    private let testSettings = HTTP3Settings(
        qpackMaximumTableCapacity: 151_288_809_941_952_652,
        qpackBlockedStreams: 1
    )

    /// These bytes encode `testSettings`.
    private let testSettingsFrameBytes: [UInt8] = [
        0x04, 0x0b, 0x07, 0x01, 0x01, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c,
    ]

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

    /// These bytes encode `testRequestHeader`.
    private var testRequestHeaderFrameBytes: [UInt8] {
        let buffer = ByteBuffer(frame: .headers(self.testRequestHeader))
        return .init(buffer: buffer)
    }

    /// These bytes encode `testResponseHeader`.
    private var testResponseHeaderFrameBytes: [UInt8] {
        let buffer = ByteBuffer(frame: .headers(self.testResponseHeader))
        return .init(buffer: buffer)
    }

    /// These bytes encode `testTrailerFrameBytes`.
    private var testTrailerFrameBytes: [UInt8] {
        let buffer = ByteBuffer(frame: .headers(self.testTrailer))
        return .init(buffer: buffer)
    }

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
        machine.assertNoNext()
    }

    @Test
    func testReadFrame() {
        var machine = HTTP3StreamStateMachine(streamType: .control, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(.init(bytes: self.testSettingsFrameBytes))
        machine.assertReturnFrame(expected: .settings(self.testSettings))
        machine.assertNoNext()
    }

    @Test
    func testDroppedFrameFollowedByNormal() {
        let decode = self.testQpackDecoderClosure()
        let testUnknownFrameBytes: [UInt8] = [0x40, 0xdb, 0x00]
        let buffer = ByteBuffer(
            bytes: testUnknownFrameBytes + self.testRequestHeaderFrameBytes + self.testDataFrameBytes
        )

        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(buffer)
        machine.assertCallAgain()
        machine.assertReceivedHeaders(decode: decode)
        machine.assertReturnFrame(expected: self.testDataFrame)
        machine.assertNoNext()
    }

    @Test
    func testQPACK() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        let action1 = machine.decodeNext()
        guard case .decodeHeader(let partialHeader) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        machine.assertNoNext()

        // The header we've been asked to decode should match the one we put in
        #expect(partialHeader == self.testRequestHeader)

        let decodeResult = self.testRequestHeaderFields
        machine.gotHeaderDecodeResult(decodeResult, from: partialHeader)
        let action2 = machine.decodeNext()
        guard case .returnFrame(let frame) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        #expect(frame == .headers(decodeResult))
    }

    @Test
    func testLotsOfQPACK() {
        let decode = self.testQpackDecoderClosure()
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        machine.buffer(.init(bytes: self.testTrailerFrameBytes))

        machine.assertReceivedHeaders(decode: decode)
        machine.assertReceivedHeaders(decode: decode)
        machine.assertNoNext()
    }

    @Test
    func testQPACKQueueing() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        // Throw in one headers and 1 data
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        machine.buffer(.init(bytes: self.testDataFrameBytes))

        let action1 = machine.decodeNext()
        guard case .decodeHeader(let partialHeader) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        // The only action available should be the decode, the 2 data frames are blocked behind that
        machine.assertNoNext()

        // Putting in further frames should still queue them and result in no action
        machine.buffer(.init(bytes: self.testDataFrameBytes))
        machine.assertNoNext()

        // The header we've been asked to decode should match the one we put in
        #expect(partialHeader == self.testRequestHeader)

        // Put in the decode result
        let decodeResult = self.testRequestHeaderFields
        machine.gotHeaderDecodeResult(decodeResult, from: partialHeader)

        // We should also be able to read more bytes now, after putting in the header decode result, before fetching back the action
        machine.buffer(.init(bytes: self.testDataFrameBytes))

        // Now the header frame can come through.
        let action2 = machine.decodeNext()
        guard case .returnFrame(let frame) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        #expect(frame == .headers(decodeResult))

        // Finally, we should be able to read the 3 data frames
        machine.assertReturnFrame(expected: self.testDataFrame)
        machine.assertReturnFrame(expected: self.testDataFrame)
        machine.assertReturnFrame(expected: self.testDataFrame)
        machine.assertNoNext()
    }

    @Test
    func testQPACKError() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        // Machine should ask us to decode a header now
        let action1 = machine.decodeNext()
        guard case .decodeHeader(let partialHeader) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        #expect(partialHeader == self.testRequestHeader)
        machine.assertNoNext()
        // We tell it we got an error
        let testError = HTTP3Error(
            code: .qpackDecoderError,
            message: "test",
            cause: nil,
            errorCode: .internalError,
            location: .here()
        )
        machine.gotHeaderDecodeError(testError, from: partialHeader)

        // Let's put in some more bytes. They should get ignored because they come after an error
        machine.buffer(.init(bytes: self.testDataFrameBytes))
        machine.assertNextIsStreamError { e in
            expectH3ErrorEqual(
                error: e,
                expectedCode: .qpackDecoderError,
                expectedH3ErrorCode: .internalError,
                expectedMessage: "test"
            )
        }
        machine.assertNoNext()

        // Again, more bytes are ignored
        machine.buffer(.init(bytes: self.testDataFrameBytes))
        machine.assertNoNext()

        // Writes also ignored due to that error
        let writeAction = machine.writeFrame(frame: .headers(self.testResponseHeaderFields))
        #expect(writeAction.isPreviousError)
    }

    @Test
    func testWriteAfterQPACKErrorBeforeRead() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        // Machine should ask us to decode a header now
        let action1 = machine.decodeNext()
        guard case .decodeHeader(let partialHeader) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        #expect(partialHeader == self.testRequestHeader)
        machine.assertNoNext()
        // We tell it we got an error
        let testError = HTTP3Error(
            code: .qpackDecoderError,
            message: "test",
            cause: nil,
            errorCode: .internalError,
            location: .here()
        )
        machine.gotHeaderDecodeError(testError, from: partialHeader)

        // Writes are now dropped
        let writeAction = machine.writeFrame(frame: .headers(self.testResponseHeaderFields))
        #expect(writeAction.isPreviousError)

        // Reading gives the error from the header decode
        machine.assertNextIsStreamError {
            expectH3ErrorEqual(
                error: $0,
                expectedCode: .qpackDecoderError,
                expectedH3ErrorCode: .internalError,
                expectedMessage: "test"
            )
        }
        machine.assertNoNext()
    }

    /// Read bytes which do not form a valid frame.
    @Test
    func testReadBadFrame() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        let badBytes = ByteBuffer(bytes: [2])  // 2 is a forbidden frame frame type
        machine.buffer(badBytes)
        let action1 = machine.decodeNext()
        guard case .emitConnectionError(let error) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        expectH3ErrorEqual(error: error, expectedCode: .forbiddenFrameType, expectedH3ErrorCode: .frameUnexpected)

        // All further reads and writes should fail
        machine.assertNoNext()

        let action3 = machine.writeFrame(frame: .headers(self.testResponseHeaderFields))
        #expect(action3.isPreviousError)
    }

    /// Read bytes which do form a valid frame, but of a type which isn't currently valid.
    /// We'll be sending a data frame when we need headers.
    @Test
    func testReadInvalidFrame() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        let badBytes = ByteBuffer(bytes: self.testDataFrameBytes)
        machine.buffer(badBytes)
        let action1 = machine.decodeNext()
        guard case .emitConnectionError(let error) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        expectH3ErrorEqual(error: error, expectedCode: .unexpectedFrame, expectedH3ErrorCode: .frameUnexpected)

        // All further reads and writes should fail
        machine.assertNoNext()

        let action3 = machine.writeFrame(frame: .headers(self.testResponseHeaderFields))
        #expect(action3.isPreviousError)
    }

    @Test
    func testRoundtrip() throws {
        let decode = self.testQpackDecoderClosure()

        var server = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        var client = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)

        // Client writes a head + data
        let clientWrite1 = client.writeFrameAndQPACK(frame: .headers(self.testRequestHeaderFields))
        try server.receiveWrite(clientWrite1)
        let clientWrite2 = client.writeFrameAndQPACK(frame: .data(.init(bytes: [1, 2, 3])))
        try server.receiveWrite(clientWrite2)

        // Server receives
        server.assertReceivedHeaders(decode: decode)
        server.assertReturnFrame(expected: .data(.init(bytes: [1, 2, 3])))

        // Server writes a head + data
        let serverWrite1 = server.writeFrameAndQPACK(frame: .headers(self.testResponseHeaderFields))
        try client.receiveWrite(serverWrite1)
        let serverWrite2 = server.writeFrameAndQPACK(frame: .data(.init(bytes: [4, 5, 6])))
        try client.receiveWrite(serverWrite2)

        // Client receives
        client.assertReceivedHeaders(decode: decode)
        client.assertReturnFrame(expected: .data(.init(bytes: [4, 5, 6])))

        // No further frames come
        server.assertNoNext()
        client.assertNoNext()
    }

    @Test
    func testDoubleResponse() throws {
        let decode = self.testQpackDecoderClosure()

        var server = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        var client = HTTP3StreamStateMachine(streamType: .request, incoming: false, preferHuffmanEncoding: false)

        // Client writes a head + data
        let clientWrite1 = client.writeFrameAndQPACK(frame: .headers(self.testRequestHeaderFields))
        try server.receiveWrite(clientWrite1)
        let clientWrite2 = client.writeFrameAndQPACK(frame: .data(.init(bytes: [1, 2, 3])))
        try server.receiveWrite(clientWrite2)

        // Server receives
        server.assertReceivedHeaders(decode: decode)
        server.assertReturnFrame(expected: .data(.init(bytes: [1, 2, 3])))

        // Server writes a double head + data
        let serverWrite1 = server.writeFrameAndQPACK(frame: .headers([.init(name: .status, value: "100")]))
        try client.receiveWrite(serverWrite1)
        let serverWrite2 = server.writeFrameAndQPACK(frame: .headers(self.testResponseHeaderFields))
        try client.receiveWrite(serverWrite2)
        let serverWrite3 = server.writeFrameAndQPACK(frame: .data(.init(bytes: [4, 5, 6])))
        try client.receiveWrite(serverWrite3)

        // Client receives
        client.assertReceivedHeaders(decode: decode)
        client.assertReceivedHeaders(decode: decode)
        client.assertReturnFrame(expected: .data(.init(bytes: [4, 5, 6])))

        // No further frames come
        server.assertNoNext()
        client.assertNoNext()
    }

    @Test
    func testWriteDuringIncomingData() {
        let decode = self.testQpackDecoderClosure()

        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        // Write request headers
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        machine.assertReceivedHeaders(decode: decode)

        // Start, but don't finish, writing request data
        machine.buffer(.init(bytes: [0, 10, 1, 2, 3]))  // type data, length 10, but we're only giving 3 bytes

        // We can send response headers, even though we're in the middle of processing incoming request data
        let writeAction = machine.writeFrameAndQPACK(frame: .headers(self.testResponseHeaderFields))
        writeAction?.assertReturnBytes(expectedBytes: .init(bytes: self.testResponseHeaderFrameBytes))
    }

    @Test
    func testWriteDuringIncomingTrailers() {
        let decode = self.testQpackDecoderClosure()

        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        // Read request headers
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        machine.assertReceivedHeaders(decode: decode)

        // Read request trailers, but don't decode them yet
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        guard case .decodeHeader = machine.decodeNext() else {
            Issue.record("Unexpected action")
            return
        }

        // We can write response headers, even though we're in the middle of processing incoming request trailers
        let writeAction1 = machine.writeFrameAndQPACK(frame: .headers(self.testResponseHeaderFields))
        writeAction1?.assertReturnBytes(expectedBytes: .init(bytes: self.testResponseHeaderFrameBytes))

        // Now decode the request trailers
        let testResult = self.testTrailerFields
        machine.gotHeaderDecodeResult(testResult, from: self.testRequestHeader)

        // The machine is now in a buffering state for reads, where it is holding on to that trailer for us. We can still write data out
        let writeAction2 = machine.writeFrameAndQPACK(frame: self.testDataFrame)
        writeAction2?.assertReturnBytes(expectedBytes: .init(bytes: self.testDataFrameBytes))

        // now we can get back the head that we fed in as the qpack result
        machine.assertReturnFrame(expected: .headers(testResult))
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
        action1?.assertReturnBytes(expectedBytes: .init(bytes: self.testRequestHeaderFrameBytes))

        let action2 = machine.writeFrameAndQPACK(frame: .data(.init(bytes: [1, 2, 3])))
        action2?.assertReturnBytes(expectedBytes: .init(bytes: [0, 3, 1, 2, 3]))

        let action3 = machine.writeFrameAndQPACK(frame: .data(.init(bytes: [4, 5, 6])))
        action3?.assertReturnBytes(expectedBytes: .init(bytes: [0, 3, 4, 5, 6]))
    }

    // MARK: Input closed

    @Test
    func testInputClosed() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.inputClosed()
        let action = machine.decodeNext()
        guard case .inputClosed = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
    }

    @Test
    func testInputClosedCantOvertakeQueuedFrame() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        machine.inputClosed()
        let action1 = machine.decodeNext()
        guard case .decodeHeader(let headerToDecode) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }

        // There is no next, despite the input close, until we decode the header
        machine.assertNoNext()
        machine.gotHeaderDecodeResult(self.testRequestHeaderFields, from: headerToDecode)

        // Now the headers are returned, then the input close, then nothing else
        machine.assertReturnFrame(expected: .headers(self.testRequestHeaderFields))
        let action2 = machine.decodeNext()
        guard case .inputClosed = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        machine.assertNoNext()
    }

    @Test
    func testInputClosedBeforeHeaderDecodeResult() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        let action1 = machine.decodeNext()
        guard case .decodeHeader(let headerToDecode) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }

        // There is no next, despite the input close, until we decode the header
        machine.inputClosed()
        machine.assertNoNext()
        machine.gotHeaderDecodeResult(self.testRequestHeaderFields, from: headerToDecode)

        // Now the headers are returned, then the input close, then nothing else
        machine.assertReturnFrame(expected: .headers(self.testRequestHeaderFields))
        let action2 = machine.decodeNext()
        guard case .inputClosed = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        machine.assertNoNext()
    }

    @Test
    func testInputClosedAfterHeaderDecodeResult() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.buffer(.init(bytes: self.testRequestHeaderFrameBytes))
        let action1 = machine.decodeNext()
        guard case .decodeHeader(let headerToDecode) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }

        // There is no next until we decode the header
        machine.assertNoNext()
        machine.gotHeaderDecodeResult(self.testRequestHeaderFields, from: headerToDecode)

        machine.inputClosed()

        // Now the headers are returned, then the input close, then nothing else
        machine.assertReturnFrame(expected: .headers(self.testRequestHeaderFields))
        let action2 = machine.decodeNext()
        guard case .inputClosed = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        machine.assertNoNext()
    }

    @Test
    func testInputClosedWithLeftoverBytes() {
        var machine = HTTP3StreamStateMachine(streamType: .control, incoming: true, preferHuffmanEncoding: false)
        // A frame is formed of a type + length + payload
        // Here we only gave a type, so it's an unfinished frame
        machine.buffer(.init(bytes: [UInt8(HTTP3FrameType.settings.rawValue)]))
        machine.assertNoNext()  // Not enough bytes to do anything

        machine.inputClosed()
        let action2 = machine.decodeNext()
        guard case .emitConnectionError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        expectH3ErrorEqual(error: error, expectedCode: .leftoverBytes, expectedH3ErrorCode: .frameError)
    }

    // MARK: Stream closed

    @Test
    func testStreamClosed() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        let action = machine.closed()
        #expect(action == .streamClosed(seenEOF: false))
        machine.assertNoNext()
    }

    @Test
    func testStreamClosedAfterError() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)

        let action1 = machine.streamErrorCaught(errorCode: QUICApplicationErrorCode(.messageError))
        #expect(action1 != nil)

        let action2 = machine.closed()
        #expect(action2 == .streamClosed(seenEOF: false))
    }

    @Test
    func testStreamClosedAfterBufferedEOF() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.inputClosed()

        let action = machine.closed()
        // We haven't seen EOF because we didn't unbuffer it. This an error on part of the user of the state machine.
        // We should unbuffer as much as possible before calling streamClosed
        #expect(action == .streamClosed(seenEOF: false))
    }

    @Test
    func testStreamClosedAfterEOF() {
        var machine = HTTP3StreamStateMachine(streamType: .request, incoming: true, preferHuffmanEncoding: false)
        machine.inputClosed()

        let action1 = machine.decodeNext()
        switch action1 {
        case .inputClosed: break  // Expected
        default: Issue.record("Unexpected action \(String(describing: action1))")
        }

        let action2 = machine.closed()
        #expect(action2 == .streamClosed(seenEOF: true))
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
        let incomingPushFrameBytes = ByteBuffer(frame: .pushPromise(.init(pushID: 1, fieldSection: testFieldSection)))
        machine.buffer(incomingPushFrameBytes)

        let action = machine.decodeNext()
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        expectH3ErrorEqual(error: error, expectedCode: .unexpectedFrame, expectedH3ErrorCode: .idError)
    }

    @Test
    func testInputAfterInputClosed() {
        var machine = HTTP3StreamStateMachine(streamType: .control, incoming: true, preferHuffmanEncoding: false)
        machine.inputClosed()
        let action1 = machine.decodeNext()
        guard case .inputClosed = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        machine.buffer(.init(bytes: self.testSettingsFrameBytes))
        machine.assertNoNext()
    }
}

extension HTTP3StreamStateMachine {
    fileprivate mutating func assertNoNext(sourceLocation: SourceLocation = #_sourceLocation) {
        let next = self.decodeNext()
        switch next {
        case .needMoreBytes, .alreadyClosed:
            break
        default:
            Issue.record("Unexpected action \(next)", sourceLocation: sourceLocation)
        }
    }

    fileprivate mutating func assertNextIsStreamError(
        verifier: (HTTP3Error) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let next = self.decodeNext()
        switch next {
        case .emitStreamError(let error):
            verifier(error)
        default:
            Issue.record("Unexpected action \(next)", sourceLocation: sourceLocation)
        }
    }

    fileprivate mutating func assertReceivedHeaders(
        decode: (HTTP3PartialFrame.Headers) -> QPACKFullDecodeResult,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let next = self.decodeNext()
        guard case .decodeHeader(let partialHeader) = next else {
            Issue.record("Unexpected action \(next)", sourceLocation: sourceLocation)
            return
        }
        self.assertNoNext(sourceLocation: sourceLocation)
        let decoded = decode(partialHeader)
        switch decoded {
        case .missingInsertCount:
            Issue.record("Unexpected result", sourceLocation: sourceLocation)
        case .success(let fields, _):
            self.gotHeaderDecodeResult(fields, from: partialHeader)
            self.assertReturnFrame(expected: .headers(fields), sourceLocation: sourceLocation)
        case .error(let qpackError):
            let error = HTTP3Error(
                code: .qpackDecoderError,
                message: "Failed to qpack decode",
                cause: qpackError,
                errorCode: .qpackDecompressionFailed,
                location: .here()
            )
            self.gotHeaderDecodeError(error, from: partialHeader)
        }
    }

    fileprivate mutating func assertCallAgain(sourceLocation: SourceLocation = #_sourceLocation) {
        let next = self.decodeNext()
        switch next {
        case .callAgain:
            break  // Expected
        default:
            Issue.record("Unexpected action \(next)", sourceLocation: sourceLocation)
        }
    }

    fileprivate mutating func assertReturnFrame(
        expected: HTTP3Frame,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let next = self.decodeNext()
        switch next {
        case .returnFrame(let frame):
            #expect(frame == expected, sourceLocation: sourceLocation)
        default:
            Issue.record("Unexpected action \(next)", sourceLocation: sourceLocation)
        }
    }

    fileprivate mutating func receiveWrite(_ action: ResolvedAction?) throws {
        switch action {
        case .none:
            break
        case .returnBytes(let bytes):
            self.buffer(bytes)
        case .wouldBeStreamError(let error):
            throw error
        case .wouldBeConnectionError(let error):
            throw error
        case .alreadyClosed:
            throw ChannelError.ioOnClosedChannel
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

extension ByteBuffer {
    /// Create a buffer and write a single frame into it.
    fileprivate init(frame: HTTP3PartialFrame) {
        self.init()
        self.writeHTTP3PartialFrame(frame, preferHuffmanEncoding: false)
    }
}
