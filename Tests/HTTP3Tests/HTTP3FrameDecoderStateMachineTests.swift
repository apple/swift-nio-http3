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
import NIOCore
import QPACK
import Testing

struct HTTP3FrameDecoderStateMachineTests {
    private let testDataFrameContent: [UInt8] = [1, 2, 3, 4]
    // Type is 0, length is 4, data is 1,2,3,4
    private let testDataFrameBytes: [UInt8] = [0, 4, 1, 2, 3, 4]

    private var testHeader: HTTP3PartialFrame.Headers {
        let fieldSectionPrefix = FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 0)
        let line = FieldLine.literal(requireLiteralRepresentation: false, name: "test", value: "hello")
        return .init(fieldSection: .init(prefix: fieldSectionPrefix, lines: [line]))
    }

    private var testHeaderFrameBytes: [UInt8] {
        let header = self.testHeader
        var buffer = ByteBuffer()
        buffer.writeFieldSectionPrefix(header.fieldSection.prefix)
        for line in header.fieldSection.lines {
            buffer.writeFieldLine(line, preferHuffmanEncoding: false)
        }
        let fieldSectionBytes = [UInt8](buffer: buffer)
        let prefix: [UInt8] = [1, UInt8(fieldSectionBytes.count)]  // prefix with frame type and length
        return prefix + fieldSectionBytes
    }

    @Test
    func testFullFrame() {
        var decoder = HTTP3FrameDecoderStateMachine()
        // send in a full data frame
        decoder.buffer(.init(bytes: self.testDataFrameBytes))
        let action = decoder.decodeNext()
        #expect(action.returnFrame == .data(.init(bytes: self.testDataFrameContent)))
    }

    @Test
    func testPartialFrame() {
        let testFrame = HTTP3PartialFrame.settings(.init(qpackMaximumTableCapacity: 1024))
        var encodedFrame = ByteBuffer()
        encodedFrame.writeHTTP3PartialFrame(testFrame, preferHuffmanEncoding: false)
        #expect(encodedFrame.readableBytes == 6)
        let bytes = [UInt8](buffer: encodedFrame)
        // drip in a frame, byte by byte, except for the last one
        var decoder = HTTP3FrameDecoderStateMachine()
        for byte in bytes.dropLast() {
            decoder.buffer(.init(bytes: [byte]))
            #expect(decoder.decodeNext().needsMoreBytes)
        }
        // Put in the last byte
        decoder.buffer(.init(bytes: [bytes.last!]))
        let action = decoder.decodeNext()
        #expect(action.returnFrame == testFrame)
    }

    @Test
    func testPartialDataFrame() {
        var decoder = HTTP3FrameDecoderStateMachine()

        decoder.buffer(.init(bytes: [0]))  // frame type data
        #expect(decoder.decodeNext().needsMoreBytes)  // Nothing useful can come yet

        decoder.buffer(.init(bytes: [4]))  // frame length 4
        #expect(decoder.decodeNext().needsMoreBytes)  // Nothing useful can come yet

        decoder.buffer(.init(bytes: [1, 2]))  // frame payload
        #expect(decoder.decodeNext().returnFrame == .data(.init(bytes: [1, 2])))  // Bytes come out as a frame

        decoder.buffer(.init(bytes: [3]))  // frame payload continued
        #expect(decoder.decodeNext().returnFrame == .data(.init(bytes: [3])))  // Bytes come out as a frame

        decoder.buffer(.init(bytes: [4]))  // frame payload continued
        #expect(decoder.decodeNext().returnFrame == .data(.init(bytes: [4])))  // Bytes come out as a frame

        decoder.buffer(.init(bytes: [0]))  // next frame begins
        #expect(decoder.decodeNext().needsMoreBytes)  // Again nothing is ready yet
    }

    @Test
    func testUnknownFrameType() {
        let bytes: [UInt8] = [12, 0]  // 12 is not a known type
        var decoder = HTTP3FrameDecoderStateMachine()
        decoder.buffer(.init(bytes: bytes))

        // There is no action, unknown frames are dropped
        #expect(decoder.decodeNext().isReturnUnknownFrame)

        // Further bytes are processed as usual
        decoder.buffer(.init(bytes: self.testDataFrameBytes))
        let action3 = decoder.decodeNext()
        #expect(action3.returnFrame == .data(.init(bytes: self.testDataFrameContent)))
    }

    @Test
    func testForbiddenFrameType() {
        let forbiddenTypes: [UInt8] = [2, 6, 8, 9]
        for type in forbiddenTypes {
            let bytes: [UInt8] = [type]
            var decoder = HTTP3FrameDecoderStateMachine()
            decoder.buffer(.init(bytes: bytes))

            let action1 = decoder.decodeNext()
            switch action1 {
            case .emitConnectionError(let error):
                expectH3ErrorEqual(
                    error: error,
                    expectedCode: .forbiddenFrameType,
                    expectedH3ErrorCode: .frameUnexpected
                )
            case .returnFrame, .needMoreBytes, .previousError, .returnUnknownFrame:
                Issue.record("Unexpected action")
            }

            // Every time we call decodeNext, we should get the `previousError` action
            let action2 = decoder.decodeNext()
            #expect(action2.previousError)

            // Further bytes are ignored, even if valid
            decoder.buffer(.init(bytes: self.testDataFrameBytes))
            let action3 = decoder.decodeNext()
            #expect(action3.previousError)
        }
    }

    @Test
    func testPartialHeader() {
        var decoder = HTTP3FrameDecoderStateMachine()
        decoder.buffer(.init(bytes: self.testHeaderFrameBytes))
        let action1 = decoder.decodeNext()
        #expect(action1.returnFrame == .headers(self.testHeader))
    }

    @Test
    func testDecodeNoBytes() {
        var decoder = HTTP3FrameDecoderStateMachine()
        let action1 = decoder.decodeNext()
        #expect(action1.needsMoreBytes)
    }

    @Test
    func testInputCloseImmediately() {
        let decoder = HTTP3FrameDecoderStateMachine()
        let leftoverBytes = decoder.inputClosed()
        // Expect no leftover bytes because the decoder has seen no incoming bytes at all
        #expect(!leftoverBytes)
    }

    @Test
    func testInputCloseCleanly() {
        var decoder = HTTP3FrameDecoderStateMachine()

        decoder.buffer(.init(bytes: self.testDataFrameBytes))
        let action = decoder.decodeNext()
        #expect(action.returnFrame == .data(.init(bytes: self.testDataFrameContent)))

        // Expect no leftover bytes because the decoder has only seen a full frame
        let leftoverBytes = decoder.inputClosed()
        #expect(!leftoverBytes)
    }

    @Test(arguments: [
        [0],  // Frame type 0, no length
        [64],  // Partial frame type (64 implies a multi-byte integer)
        [0, 5, 1],  // Frame type + length but incomplete data (only 1 byte of data, expecting 5)
        [0, 1, 1, 0, 1],  // A full frame, followed by a frame with missing payload
    ])
    func testInputCloseUnclean(testData: [UInt8]) {
        var decoder = HTTP3FrameDecoderStateMachine()

        decoder.buffer(.init(bytes: testData))
        while case .returnFrame = decoder.decodeNext() {
            // Not interested in what comes out. We just want to consume all the full frames
        }

        // We expect there to be some leftover bytes
        let leftoverBytes = decoder.inputClosed()
        #expect(leftoverBytes)
    }

    @Test
    func testByteReclaimAfterLargeFrame() {
        // Buffer a data frame containing 2048 bytes of payload. The initial buffer capacity is 4096 bytes. After
        // decoding, the `readerIndex` will be 2051 (1 byte frame type + 2 byte length + 2048 byte payload), which is
        // over the 50% threshold, so reclamation should fire when calling `decodeNext()`.
        var decoder = HTTP3FrameDecoderStateMachine()

        let largePayload = ByteBuffer(repeating: 1, count: 2048)
        var encoded = ByteBuffer()
        encoded.writeHTTP3PartialFrame(.data(.init(payload: largePayload)), preferHuffmanEncoding: false)

        decoder.buffer(encoded)
        // When `buffer()` is called on an idle state machine, the provided ByteBuffer is used directly as the internal
        // decoding buffer. So `encoded.capacity` is the capacity of the decoder's buffer.
        #expect(decoder._testOnlyBufferCapacity == 4096)
        #expect(decoder._testOnlyBufferWriterIndex == 2051)

        // After buffering but before decoding, the `readerIndex` should be 0 (nothing has been read yet).
        #expect(decoder._testOnlyBufferReaderIndex == 0)

        let action = decoder.decodeNext()
        #expect(action.returnFrame == .data(.init(payload: largePayload)))

        // After decoding, reclamation should have been triggered (`readerIndex` was > 2048).
        #expect(decoder._testOnlyBufferReaderIndex == 0)
    }

    @Test
    func testByteReclaimAfterManySmallFrames() {
        // Feed many small data frames. This will result in the buffer's capacity being 4096 bytes. Then decode all
        // frames to make `readerIndex` cross the 2048 bytes threshold. Each frame is 6 bytes:
        // - After decoding 341 frames: `readerIndex` = 2046 (< 2048, no reclamation).
        // - After decoding the 342nd frame: `readerIndex` = 2052 (> 2048, reclamation should fire).
        var decoder = HTTP3FrameDecoderStateMachine()

        var allBytes = ByteBuffer()
        for _ in 0..<342 {
            allBytes.writeBytes(self.testDataFrameBytes)
        }

        decoder.buffer(allBytes)
        #expect(decoder._testOnlyBufferReaderIndex == 0)
        #expect(decoder._testOnlyBufferWriterIndex == 342 * self.testDataFrameBytes.count)
        #expect(decoder._testOnlyBufferCapacity == 4096)

        // Decode 341 frames: just below the threshold.
        for _ in 0..<341 {
            let action = decoder.decodeNext()
            #expect(action.returnFrame == .data(.init(payload: ByteBuffer(bytes: self.testDataFrameContent))))
        }
        // `readerIndex` should be 341 * 6 = 2046. Reclamation shouldn't have fired yet.
        #expect(decoder._testOnlyBufferReaderIndex == 2046)

        // Decode one more frame to cross the 2048 bytes threshold. Reclamation should fire.
        let action = decoder.decodeNext()
        #expect(action.returnFrame == .data(.init(payload: ByteBuffer(bytes: self.testDataFrameContent))))
        #expect(decoder._testOnlyBufferReaderIndex == 0)
    }

    @Test
    func testByteReclaimWithPartiallyDecodedFrame() {
        // Verify that reclamation preserves unread bytes when a partial frame remains in the buffer.
        var decoder = HTTP3FrameDecoderStateMachine()

        let largePayload = ByteBuffer(repeating: 1, count: 2048)
        let settingsFrame = HTTP3PartialFrame.settings(.init(qpackMaximumTableCapacity: 512))

        // Encode the settings frame and split it. The first byte goes into the initial buffer, and the remainder will
        // be buffered later.
        var settingsEncoded = ByteBuffer()
        settingsEncoded.writeHTTP3PartialFrame(settingsFrame, preferHuffmanEncoding: false)
        let settingsFirstByte = settingsEncoded.readSlice(length: 1)!
        let settingsRemainder = settingsEncoded

        var encoded = ByteBuffer()
        encoded.writeHTTP3PartialFrame(.data(.init(payload: largePayload)), preferHuffmanEncoding: false)
        // Write only the first byte of the settings frame.
        encoded.writeImmutableBuffer(settingsFirstByte)

        decoder.buffer(encoded)
        #expect(decoder._testOnlyBufferCapacity == 4096)

        let action1 = decoder.decodeNext()
        #expect(action1.returnFrame == .data(.init(payload: largePayload)))

        // After decoding the large frame, `readerIndex` should have moved to 2051 (> 2048), which should have then
        // triggered reclamation. Now `readerIndex` should be 0.
        #expect(decoder._testOnlyBufferReaderIndex == 0)
        // Check that the partial byte is still buffered:
        #expect(decoder._testOnlyBufferWriterIndex == 1)
        #expect(decoder.decodeNext().needsMoreBytes == true)

        // Buffer the rest of the settings frame.
        decoder.buffer(settingsRemainder)

        let action2 = decoder.decodeNext()
        #expect(action2.returnFrame == settingsFrame)
        #expect(decoder._testOnlyBufferReaderIndex == (1 + settingsRemainder.readableBytes))
    }
}

extension HTTP3FrameDecoderStateMachine.DecodeAction {
    fileprivate var returnFrame: HTTP3PartialFrame? {
        switch self {
        case .returnFrame(let f): return f
        case .emitConnectionError, .previousError, .needMoreBytes, .returnUnknownFrame: return nil
        }
    }

    fileprivate var isReturnUnknownFrame: Bool {
        switch self {
        case .returnUnknownFrame: return true
        case .returnFrame, .emitConnectionError, .previousError, .needMoreBytes: return false
        }
    }

    fileprivate var needsMoreBytes: Bool {
        switch self {
        case .needMoreBytes: return true
        case .emitConnectionError, .previousError, .returnFrame, .returnUnknownFrame: return false
        }
    }

    fileprivate var previousError: Bool {
        switch self {
        case .previousError: return true
        case .emitConnectionError, .needMoreBytes, .returnFrame, .returnUnknownFrame: return false
        }
    }
}
