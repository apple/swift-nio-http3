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
import NIOQUICHelpers
import QPACK
import Testing

struct QPACKStateMachineTests {
    @Test
    func testBeginUsingDynamicTable() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
    }

    @Test
    func testSettingsWithoutDynamicTable() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let action = stateMachine.receivedRemoteSettings(maxQueueSize: 0, effectiveDynamicTableSize: 0)
        switch action {
        case .makeEncoderInstructionStream:
            Issue.record("Expected no outbound encoder stream")
            return
        case .none:
            break  // Good
        }
    }

    // MARK: Encoding headers

    @Test
    func testEncodeHeadersInInitialState() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let result = stateMachine.encodeHeaders([.init(name: .cookie, value: "test")], forStream: 1)
        #expect(
            result.fieldSection.lines
                == [
                    .literalWithNameReference(
                        requireLiteralRepresentation: false,
                        table: .staticTable,
                        index: 5,
                        value: "test"
                    )
                ]
        )
    }

    @Test
    func testEncodeHeadersInWaitingForStreamState() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let action = stateMachine.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 100)
        #expect(action == .makeEncoderInstructionStream)
        // We have received remote settings, and been asked to create outbound encoder stream
        // However, the outbound stream isn't ready yet, so the dynamic table should not be used
        stateMachine.assertEncodesWithoutUsingDynamicTable()
    }

    @Test
    func testEncodeHeadersInWithoutDynamicState() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let action = stateMachine.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 0)
        #expect(action == nil)  // No outbound stream because 0 size
        // We have received remote settings, but they specify 0 table size. Therefore we should not use dynamic table
        stateMachine.assertEncodesWithoutUsingDynamicTable()
    }

    @Test
    func testEncodeHeadersInWithDynamicState() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let action1 = stateMachine.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 300)
        #expect(action1 == .makeEncoderInstructionStream)
        let action2 = stateMachine.outboundEncoderStreamReady()
        // The stream is ready so we should immediately start using the table at max capacity
        #expect(action2 == .sendEncoderInstruction(.setDynamicTableCapacity(300)))

        // Doing an encode should now use the table
        let encodeResult = stateMachine.encodeHeaders([.init(name: .cookie, value: "test")], forStream: 1)
        let expectedPrefix = FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 300)
        let expectedFieldSection = FieldSection(
            prefix: expectedPrefix,
            lines: [.indexedWithPostBase(index: 0)]
        )
        #expect(encodeResult.fieldSection == expectedFieldSection)
        #expect(
            encodeResult.instructions
                == [.insertWithNameReference(.staticTable, relativeIndex: 5, value: "test")]
        )
    }

    // MARK: Decoding headers

    @Test
    func testDecodeHeadersWithoutDynamicTable() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(0)
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: .init(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
                lines: [.literal(requireLiteralRepresentation: false, name: "cookie", value: "test")]
            )
        )
        let action = stateMachine.decodeHeaders(testHeader, forStream: streamID)
        guard case .informDecodeResult(let result) = action else {
            Issue.record("Unexpected action \(String(describing: action))")
            return
        }
        #expect(
            result
                == QPACKStateMachine.DecodeHeaderAction.InformDecodeResult(
                    fields: [.init(name: .cookie, value: "test")],
                    headers: testHeader,
                    streamID: streamID,
                    instructionToWrite: nil
                )
        )
    }

    @Test
    func testDecodeHeadersWithDynamicTable() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(0)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // Give the machine a table entry
        let actions1 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "cookie", value: "test")
        )
        #expect(actions1?.decoderInstructions == .insertCountIncrement(increment: 1))

        // Ask the machine to decode a header section containing reference to the new entry
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        let actions2 = stateMachine.decodeHeaders(testHeader, forStream: streamID)
        guard case .informDecodeResult(let decodeResult) = actions2 else {
            Issue.record("Unexpected action \(String(describing: actions2))")
            return
        }
        #expect(
            decodeResult
                == QPACKStateMachine.DecodeHeaderAction.InformDecodeResult(
                    fields: [.init(name: .cookie, value: "test")],
                    headers: testHeader,
                    streamID: streamID,
                    instructionToWrite: .sectionAcknowledgement(streamID: streamID)
                )
        )
    }

    @Test
    func testDecodeHeadersConnectionError() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(0)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // Ask the machine to decode some nonsense header. This is a connection level failure because the references don't exist
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        let action2 = stateMachine.decodeHeaders(testHeader, forStream: streamID)

        guard case .emitConnectionError(let error) = action2 else {
            Issue.record("Unexpected actions \(String(describing: action2))")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .qpackDecompressionFailed
        )
    }

    @Test
    func testDecodeHeadersStreamError() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(0)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // This header will decode fine, but is a malformed message (upper case field names). This is a stream error
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 0),
                lines: [.literal(requireLiteralRepresentation: false, name: "ILLEGAL", value: "value")]
            )
        )
        let action2 = stateMachine.decodeHeaders(testHeader, forStream: streamID)
        guard case .informDecodeError(let error) = action2 else {
            Issue.record("Unexpected actions \(String(describing: action2))")
            return
        }
        #expect(error.headers == testHeader)
        #expect(error.streamID == streamID)
        expectH3ErrorEqual(error: error.error, expectedCode: .qpackDecoderError, expectedH3ErrorCode: .messageError)
    }

    @Test
    func testDecodeHeadersWithDynamicTableDelayed() throws {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(0)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // Ask the machine to decode a header section containing dynamic table references
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        let actions3 = stateMachine.decodeHeaders(testHeader, forStream: streamID)
        // The machine can't decode it, because it hasn't received that entry yet
        #expect(actions3 == nil)

        // Give it the entry
        let action4 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "cookie", value: "test")
        )
        #expect(action4?.decoderInstructions == .insertCountIncrement(increment: 1))

        let action5 = stateMachine.checkPendingDecodes()
        #expect(
            action5
                == .informDecodeResult(
                    .init(
                        fields: [.init(name: .cookie, value: "test")],
                        headers: testHeader,
                        streamID: streamID,
                        instructionToWrite: .sectionAcknowledgement(streamID: streamID)
                    )
                )
        )
        #expect(stateMachine.checkPendingDecodes() == nil)
    }

    @Test
    func testDecodeHeadersStreamErrorDelayed() throws {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(0)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // Ask the machine to decode a header section containing dynamic table references, plus an invalid literal
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [
                    .indexedWithPostBase(index: 0),
                    // Invalid due to uppercase
                    .literal(requireLiteralRepresentation: false, name: "Test", value: "test"),
                ]
            )
        )
        let actions3 = stateMachine.decodeHeaders(testHeader, forStream: streamID)
        // The machine can't decode it, because it hasn't received that entry yet
        #expect(actions3 == nil)

        // Give it the entry
        let actions4 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "cookie", value: "test")
        )
        #expect(actions4?.decoderInstructions == .insertCountIncrement(increment: 1))

        // Decoding now becomes possible and gives us the error
        let action5 = stateMachine.checkPendingDecodes()
        guard case .informDecodeError(let decodeError) = action5 else {
            Issue.record("Unexpected action \(String(describing: action5))")
            return
        }
        #expect(decodeError.headers == testHeader)
        #expect(decodeError.streamID == streamID)
        expectH3ErrorEqual(
            error: decodeError.error,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .messageError
        )
    }

    @Test
    func testInvalidFieldPrefix() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(0)
        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: .init(encodedRequiredInsertCount: 200, deltaBase: 100, signBit: true),
                lines: [
                    .literal(requireLiteralRepresentation: false, name: "test", value: "test")
                ]
            )
        )
        let actions3 = stateMachine.decodeHeaders(testHeader, forStream: streamID)
        // The machine can't decode it, because the prefix is nonsense
        guard case .emitConnectionError(let error) = actions3 else {
            Issue.record("Unexpected action \(String(describing: actions3))")
            return
        }
        expectH3ErrorEqual(
            error:
                error,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .qpackDecompressionFailed,
            expectedMessage: "Invalid field section prefix"
        )
    }

    @Test
    func testMaxBlockedStreams() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 3)

        let streamID1 = QUICStreamID(1)
        let streamID2 = QUICStreamID(2)
        let streamID3 = QUICStreamID(3)
        let streamID4 = QUICStreamID(4)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // a header which requires an insert count of 1
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 1024),
                lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "test")]
            )
        )

        // Max blocked streams is 3, so the first 3 are fine, they just get queued
        let action1 = stateMachine.decodeHeaders(testHeader, forStream: streamID1)
        #expect(action1 == nil)
        let action2 = stateMachine.decodeHeaders(testHeader, forStream: streamID2)
        #expect(action2 == nil)
        let action3 = stateMachine.decodeHeaders(testHeader, forStream: streamID3)
        #expect(action3 == nil)

        // Trying to queue on a 4th stream is a connection error
        // RFC 9204 2.1.2: If a decoder encounters more blocked streams than it promised to support, it MUST treat this as a connection error of type QPACK_DECOMPRESSION_FAILED.
        let action4 = stateMachine.decodeHeaders(testHeader, forStream: streamID4)
        guard case .emitConnectionError(let error) = action4 else {
            Issue.record("Unexpected action \(String(describing: action4))")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .qpackDecompressionFailed,
            expectedMessage: "Too many streams blocked on QPACK"
        )
    }

    @Test
    func testDecodeInstructionsBufferedWhenStreamNotReady() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)

        // Give the machine a table entry
        let action1 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "cookie", value: "test")
        )
        // Would normally expect the action to be to send an insert count increment, but we don't because the outbound stream isn't ready
        #expect(action1?.decoderInstructions == nil)

        // Ask the machine to decode a header section containing reference to the new entry
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        let streamID = QUICStreamID(0)
        let actions2 = stateMachine.decodeHeaders(testHeader, forStream: streamID)
        // The action is only to inform the decode result, there is no section acknowledgment because the outbound stream isn't ready
        #expect(
            actions2
                == .informDecodeResult(
                    .init(
                        fields: [.init(name: .cookie, value: "test")],
                        headers: testHeader,
                        streamID: streamID,
                        instructionToWrite: nil
                    )
                )
        )

        // Make the outbound stream be ready. This should tell us to send the 2 instructions buffered from before
        let actions3 = stateMachine.outboundDecoderStreamReady()
        #expect(
            actions3
                == .sendDecoderInstructions([
                    .insertCountIncrement(increment: 1), .sectionAcknowledgement(streamID: streamID),
                ])
        )

        // Further instructions should not be buffered
        let actions4 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "cookie", value: "test2")
        )
        #expect(actions4?.decoderInstructions == .insertCountIncrement(increment: 1))
    }

    // MARK: Decoder instructions

    @Test
    func testGotIncomingDecoderInstruction() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        let streamID = QUICStreamID(4)
        _ = stateMachine.encodeHeaders([.init(name: .cookie, value: "test")], forStream: streamID)
        let actions = stateMachine.receivedIncomingDecoderInstruction(
            .sectionAcknowledgement(streamID: streamID)
        )
        #expect(actions == nil)
    }

    @Test
    func testGotDecoderInstructionWhenImplicitlyNoDynamicTable() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        // This instruction is invalid because there is no dynamic table initially and no stream with id 1
        let action = stateMachine.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: 1))
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .qpackDecoderStreamError,
            expectedH3ErrorCode: .qpackDecoderStreamError
        )
    }

    @Test
    func testGotDecoderInstructionWhenExplicitlyNoDynamicTable() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        _ = stateMachine.receivedRemoteSettings(maxQueueSize: 0, effectiveDynamicTableSize: 0)
        // This instruction is invalid because remote explicitly told us no dynamic table capacity
        let action = stateMachine.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: 1))
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .qpackDecoderStreamError,
            expectedH3ErrorCode: .qpackDecoderStreamError
        )
    }

    @Test
    func testGotDecoderInstructionWhenAwaitingStream() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        _ = stateMachine.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 100)
        // We can't receive instructions from the remote decoder until we ourselves have sent an instruction to indicate support of the dynamic table
        let action = stateMachine.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: 1))
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .qpackDecoderStreamError,
            expectedH3ErrorCode: .qpackDecoderStreamError
        )
    }

    @Test
    func testGotInvalidIncomingDecoderInstruction() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        stateMachine.setupRemoteDynamicTable(maxSize: 1)
        // This instruction is invalid because we can't ack an insert which hasn't happened
        let action = stateMachine.receivedIncomingDecoderInstruction(.insertCountIncrement(increment: 1))
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .qpackDecoderStreamError,
            expectedH3ErrorCode: .qpackDecoderStreamError
        )
    }

    // MARK: Encoder instructions

    @Test
    func testGotInvalidIncomingEncoderInstruction() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)

        // Invalid because 1025 is higher than allowed max capacity
        let action = stateMachine.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1025))
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .qpackEncoderStreamError,
            expectedH3ErrorCode: .qpackEncoderStreamError
        )
    }

    @Test
    func testInsertTooLargeEntry() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1, decoderMaxBlockedStreams: 100)

        let action1 = stateMachine.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1))
        #expect(action1?.decoderInstructions == nil)

        // Capacity is only 1, so inserting this is a connection level error
        let action2 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "toooo", value: "long")
        )
        /// It is an error if the encoder attempts to add an entry that is larger than the dynamic table capacity; the decoder MUST treat this as a connection error of type QPACK_ENCODER_STREAM_ERROR.
        guard case .emitConnectionError(let error) = action2 else {
            Issue.record("Unexpected action")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .qpackEncoderStreamError,
            expectedH3ErrorCode: .qpackEncoderStreamError
        )
    }

    // MARK: Request stream closing

    @Test
    func testClosedRequestStreamAfterEOF() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(1)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // Cancel the stream
        let actions = stateMachine.requestStreamClosed(streamID: streamID, seenEOF: true)
        #expect(actions == nil)
    }

    @Test
    func testClosedRequestStreamBeforeEOFWithoutDynamicTable() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(1)

        // Cancel the stream
        let actions = stateMachine.requestStreamClosed(streamID: streamID, seenEOF: false)
        #expect(actions == nil)  // No instruction to send, because no dynamic table
    }

    @Test
    func testClosedRequestStreamWhilstDecodingQPACK() {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)
        let streamID = QUICStreamID(1)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // Ask the machine to decode a header section containing reference which doesn't exist.
        let testHeader = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        let actions1 = stateMachine.decodeHeaders(testHeader, forStream: streamID)
        // The state machine will have queued the decoding, so we don't have an action yet.
        #expect(actions1 == nil)

        // We tell the state machine that the stream has gone away, so it'll remove the pending decode from the queue.
        // Also, it will tell us to inform the remote that we've cancelled the stream, so the remote will know that we won't be acking the relevant field sections.
        let actions2 = stateMachine.requestStreamClosed(streamID: streamID, seenEOF: false)
        #expect(actions2 == .sendDecoderInstruction(.streamCancellation(streamID: streamID)))

        // Give the machine the table entry. Normally, this would allow the machine to complete the queued decode. But the decode is no longer in the queue.
        // So we have no action (only the insert count increment, which we always have on every insert)
        let actions3 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "cookie", value: "test")
        )
        #expect(actions3?.decoderInstructions == .insertCountIncrement(increment: 1))
    }

    /// This tests the scenario where a request is fully completed, the stream is closed, and then an ack comes in on the QPACK decoder stream for that request.
    /// This test is for a potential bug where we accidentally treat it as an error to receive an ack for a 'nonexistent' stream.
    @Test
    func testClosedRequestStreamThenReceiveSectionAck() throws {
        var stateMachine = QPACKStateMachine(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100)

        stateMachine.setupRemoteDynamicTable(maxSize: 1024)
        stateMachine.setupLocalDynamicTable(maxSize: 1024)
        stateMachine.setupOutboundDecoderStream()

        // An outbound request stream is made
        let streamID = QUICStreamID(0)

        // Some fields are encoded to be sent on that stream
        _ = stateMachine.encodeHeaders([.init(name: .cookie, value: "test")], forStream: streamID)

        // The stream is closed cleanly
        _ = stateMachine.requestStreamClosed(streamID: streamID, seenEOF: true)

        // An ack comes in for the field section
        let action = stateMachine.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: streamID))
        switch action {
        case .emitConnectionError(let error):
            throw error  // unexpected
        case .none:
            break  // expected
        }
    }
}

extension QPACKStateMachine.DecodeHeaderAction: Equatable {
    static func == (lhs: QPACKStateMachine.DecodeHeaderAction, rhs: QPACKStateMachine.DecodeHeaderAction) -> Bool {
        switch (lhs, rhs) {
        case (.informDecodeResult(let l), .informDecodeResult(let r)):
            return l == r
        case (.informDecodeError, .informDecodeError):
            return false  // no good way to equate these
        default:
            return false
        }
    }
}

extension QPACKStateMachine {
    /// Simulate receiving settings from the remote which allows the local encoder to use the dynamic table.
    fileprivate mutating func setupRemoteDynamicTable(maxSize: Int) {
        // remote sends us settings saying we may use the dynamic table
        let actions1 = self.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: maxSize)
        switch actions1 {
        // We open an encoder stream
        case .makeEncoderInstructionStream:
            let actions2 = self.outboundEncoderStreamReady()
            // we send an instruction on the stream telling the remote that we want to use the table
            let expectedInstruction = QPACKEncoderInstruction.setDynamicTableCapacity(maxSize)
            #expect(actions2 == .sendEncoderInstruction(expectedInstruction))
        case .none:
            Issue.record("Unexpected action")
        }
    }

    /// Simulate the remote sending the local an instruction telling the local that it wants to use the dynamic table.
    fileprivate mutating func setupLocalDynamicTable(maxSize: Int) {
        let action = self.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(maxSize))
        switch action {
        case .emitConnectionError:
            Issue.record("Unexpected error")
        case .sendDecoderInstruction(let instruction):
            Issue.record("Unexpected instruction \(instruction)")
        case .none:
            break
        }
    }

    fileprivate mutating func setupOutboundDecoderStream() {
        let actions = self.outboundDecoderStreamReady()
        #expect(actions == nil)
    }

    fileprivate mutating func assertEncodesWithoutUsingDynamicTable() {
        let result = self.encodeHeaders([.init(name: .cookie, value: "test")], forStream: 1)
        #expect(
            result.fieldSection.lines
                == [
                    .literalWithNameReference(
                        requireLiteralRepresentation: false,
                        table: .staticTable,
                        index: 5,
                        value: "test"
                    )
                ]
        )
    }
}

extension QPACKStateMachine.IncomingEncoderInstructionAction {
    fileprivate var decoderInstructions: QPACKDecoderInstruction? {
        switch self {
        case .sendDecoderInstruction(let decoderInstruction): return decoderInstruction
        case .emitConnectionError: return nil
        }
    }
}
