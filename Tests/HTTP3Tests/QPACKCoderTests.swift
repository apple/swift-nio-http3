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
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK
import Testing

@_spi(PackageInternal) @testable import HTTP3

/// Tests for ``QPACKCoder``.
///
/// The coder is a thin layer over ``QPACKStateMachine``, routing its actions to the outbound streams, the
/// connection and the decode receivers. The state machine itself is covered by ``QPACKStateMachineTests``, so
/// these tests are about the routing.
struct QPACKCoderTests {

    // MARK: Remote settings

    @Test func remoteSettingsWithDynamicTableAsksForEncoderStream() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        coder.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 1024)

        #expect(connection.madeOutboundEncoderStreamCount == 1)
        #expect(connection.errors.isEmpty)
    }

    @Test func remoteSettingsWithoutDynamicTableDoesNotAskForEncoderStream() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        // RFC 9204 § 4.2: An endpoint MAY avoid creating an encoder stream if it will not be used.
        coder.receivedRemoteSettings(maxQueueSize: 0, effectiveDynamicTableSize: 0)

        #expect(connection.madeOutboundEncoderStreamCount == 0)
        #expect(connection.errors.isEmpty)
    }

    // MARK: Encoder stream

    @Test func outboundEncoderStreamReadySendsTableCapacity() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        coder.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 300)
        #expect(connection.madeOutboundEncoderStreamCount == 1)

        let encoderStream = TestOutboundEncoderStream()
        coder.outboundEncoderStreamReady(encoderStream)

        #expect(encoderStream.instructions == [.setDynamicTableCapacity(300)])
    }

    // MARK: Encode

    @Test func encodeHeadersWithoutDynamicTableSendsNoInstructions() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        // No remote settings yet, so the static encoder must be used. Note there is no encoder stream set on the
        // coder at all here: if it tried to send an instruction it would trap.
        let headers = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: 1)

        #expect(
            headers.fieldSection.lines == [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 5,
                    value: "test"
                )
            ]
        )
    }

    @Test func encodeHeadersWhileAwaitingEncoderStreamSendsNoInstructions() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        // The peer permits the dynamic table, so an encoder stream has been requested, but it isn't here yet. The
        // coder must stay on the static encoder: it holds no stream to write instructions to, and would trap.
        coder.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 300)
        #expect(connection.madeOutboundEncoderStreamCount == 1)

        let headers = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: 1)

        #expect(
            headers.fieldSection.lines == [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 5,
                    value: "test"
                )
            ]
        )
    }

    @Test func encodeHeadersWithDynamicTableForwardsInstructions() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let encoderStream = TestOutboundEncoderStream()

        coder.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 300)
        coder.outboundEncoderStreamReady(encoderStream)
        #expect(encoderStream.instructions == [.setDynamicTableCapacity(300)])
        encoderStream.instructions.removeAll()

        let headers = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: 1)

        // The entry was inserted into the dynamic table, so the peer's decoder needs to be told about it.
        #expect(encoderStream.instructions == [.insertWithNameReference(.staticTable, relativeIndex: 5, value: "test")])
        #expect(
            headers.fieldSection
                == FieldSection(
                    prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 300),
                    lines: [.indexedWithPostBase(index: 0)]
                )
        )
    }

    // MARK: Decoder stream

    @Test func outboundDecoderStreamReadyFlushesBufferedInstructions() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        // The peer inserts an entry before our decoder stream exists, so the acknowledgement must be buffered.
        coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))
        coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))

        let decoderStream = TestOutboundDecoderStream()
        coder.outboundDecoderStreamReady(decoderStream)
        #expect(decoderStream.instructions == [.insertCountIncrement(increment: 1)])
    }

    @Test func outboundDecoderStreamReadyWithNothingBuffered() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        let decoderStream = TestOutboundDecoderStream()
        coder.outboundDecoderStreamReady(decoderStream)
        #expect(decoderStream.instructions.isEmpty)
    }

    // MARK: Decode

    @Test func decodeHeadersDeliversResultSynchronously() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        coder.outboundDecoderStreamReady(decoderStream)

        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: .init(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
                lines: [.literal(requireLiteralRepresentation: false, name: "cookie", value: "test")]
            )
        )
        coder.decodeHeaders(headers, streamID: 0, decodeReceiver: receiver)

        #expect(receiver.decodedFields == [[.init(name: .cookie, value: "test")]])
        // A field section which only uses the static table needs no acknowledgement.
        #expect(decoderStream.instructions.isEmpty)
        #expect(connection.errors.isEmpty)
    }

    @Test func decodeHeadersSendsSectionAcknowledgement() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        let streamID = QUICStreamID(0)

        coder.outboundDecoderStreamReady(decoderStream)
        coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))
        coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))
        #expect(decoderStream.instructions == [.insertCountIncrement(increment: 1)])
        decoderStream.instructions.removeAll()

        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        coder.decodeHeaders(headers, streamID: streamID, decodeReceiver: receiver)

        #expect(receiver.decodedFields == [[.init(name: .cookie, value: "test")]])
        // The field section referenced the dynamic table, so the peer's encoder must be acknowledged.
        #expect(decoderStream.instructions == [.sectionAcknowledgement(streamID: streamID)])
    }

    @Test func blockedDecodeIsDeliveredOnceUnblocked() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        let streamID = QUICStreamID(0)

        coder.outboundDecoderStreamReady(decoderStream)
        coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))

        // This field section references an entry we haven't been told about yet, so the stream becomes blocked.
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        coder.decodeHeaders(headers, streamID: streamID, decodeReceiver: receiver)
        #expect(receiver.results.isEmpty)

        // The missing entry arrives, which unblocks the decode.
        coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))

        #expect(receiver.decodedFields == [[.init(name: .cookie, value: "test")]])
        #expect(
            decoderStream.instructions == [
                .insertCountIncrement(increment: 1),
                .sectionAcknowledgement(streamID: streamID),
            ]
        )
        #expect(connection.errors.isEmpty)
    }

    @Test func oneInstructionUnblocksAllWaitingStreams() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()

        coder.outboundDecoderStreamReady(decoderStream)
        coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))

        // Three streams all block on the very same missing entry.
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        let streamIDs: [QUICStreamID] = [0, 4, 8]
        let receivers = streamIDs.map { streamID -> TestDecodeReceiver in
            let receiver = TestDecodeReceiver()
            coder.decodeHeaders(headers, streamID: streamID, decodeReceiver: receiver)
            #expect(receiver.results.isEmpty)
            return receiver
        }

        // One instruction supplies the entry all three were waiting for.
        coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))

        for receiver in receivers {
            #expect(receiver.decodedFields == [[.init(name: .cookie, value: "test")]])
        }
        // Ack order is unspecified: pending decodes sit in a heap keyed on required insert count, and these tie.
        #expect(decoderStream.instructions.first == .insertCountIncrement(increment: 1))
        #expect(
            Set(decoderStream.instructions.dropFirst())
                == Set(streamIDs.map { .sectionAcknowledgement(streamID: $0) })
        )
        #expect(connection.errors.isEmpty)
    }

    @Test func streamsBlockedOnDifferentInsertCountsUnblockInOrder() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()

        coder.outboundDecoderStreamReady(decoderStream)
        coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))

        // Stream 4 needs two entries, stream 0 needs only the first.
        func headers(requiredInsertCount: Int) -> HTTP3PartialFrame.Headers {
            HTTP3PartialFrame.Headers(
                fieldSection: FieldSection(
                    prefix: FieldSectionPrefix(requiredInsertCount: requiredInsertCount, base: 0)
                        .encode(maxCapacity: 1024),
                    lines: [.indexedWithPostBase(index: requiredInsertCount - 1)]
                )
            )
        }
        let receiver0 = TestDecodeReceiver()
        let receiver4 = TestDecodeReceiver()
        coder.decodeHeaders(headers(requiredInsertCount: 2), streamID: 4, decodeReceiver: receiver4)
        coder.decodeHeaders(headers(requiredInsertCount: 1), streamID: 0, decodeReceiver: receiver0)

        // The first entry only unblocks stream 0.
        coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "one"))
        #expect(receiver0.decodedFields == [[.init(name: .cookie, value: "one")]])
        #expect(receiver4.results.isEmpty)

        // The second entry unblocks stream 4.
        coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "two"))
        #expect(receiver4.decodedFields == [[.init(name: .cookie, value: "two")]])
        #expect(receiver0.results.count == 1)
        #expect(connection.errors.isEmpty)
    }

    @Test func decodeStreamErrorOnlyFailsTheStream() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        coder.outboundDecoderStreamReady(decoderStream)

        // This decodes fine, but an uppercase field name is a malformed message: a stream level error.
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 0),
                lines: [.literal(requireLiteralRepresentation: false, name: "ILLEGAL", value: "value")]
            )
        )
        coder.decodeHeaders(headers, streamID: 0, decodeReceiver: receiver)

        #expect(receiver.results.count == 1)
        expectH3ErrorEqual(
            error: receiver.errors.first,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .messageError
        )
        // A stream level error must not take down the connection.
        #expect(connection.errors.isEmpty)
    }

    @Test func decodeConnectionErrorFailsStreamAndConnection() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        coder.outboundDecoderStreamReady(decoderStream)

        // A reference to a dynamic table entry which doesn't exist is a connection error.
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        coder.decodeHeaders(headers, streamID: 0, decodeReceiver: receiver)

        expectH3ErrorEqual(
            error: connection.errors.first,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .qpackDecompressionFailed
        )
        // The stream is told about the failure too, so that it doesn't wait for a result which will never come.
        expectH3ErrorEqual(
            error: receiver.errors.first,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .qpackDecompressionFailed
        )
    }

    @Test func invalidFieldSectionPrefixIsAConnectionError() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        coder.outboundDecoderStreamReady(decoderStream)

        // RFC 9204 § 4.5.1.1: an EncodedInsertCount which no conformant encoder could have produced is a
        // connection error of type QPACK_DECOMPRESSION_FAILED.
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: .init(encodedRequiredInsertCount: 200, deltaBase: 100, signBit: true),
                lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "test")]
            )
        )
        coder.decodeHeaders(headers, streamID: 0, decodeReceiver: receiver)

        expectH3ErrorEqual(
            error: connection.errors.first,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .qpackDecompressionFailed,
            expectedMessage: "Invalid field section prefix"
        )
        #expect(receiver.errors.count == 1)
    }

    @Test func tooManyBlockedStreamsIsAConnectionError() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 1, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        coder.outboundDecoderStreamReady(decoderStream)

        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 1024),
                lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "test")]
            )
        )

        // We promised to support one blocked stream, so the first one is simply queued.
        let receiver1 = TestDecodeReceiver()
        coder.decodeHeaders(headers, streamID: 1, decodeReceiver: receiver1)
        #expect(receiver1.results.isEmpty)
        #expect(connection.errors.isEmpty)

        // RFC 9204 § 2.1.2: more blocked streams than promised is a connection error.
        let receiver2 = TestDecodeReceiver()
        coder.decodeHeaders(headers, streamID: 2, decodeReceiver: receiver2)
        expectH3ErrorEqual(
            error: connection.errors.first,
            expectedCode: .qpackDecoderError,
            expectedH3ErrorCode: .qpackDecompressionFailed,
            expectedMessage: "Too many streams blocked on QPACK"
        )
        #expect(receiver2.errors.count == 1)
    }

    // MARK: Incoming instructions

    @Test func invalidIncomingEncoderInstructionIsAConnectionError() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        // Invalid because it exceeds the capacity we advertised.
        coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1025))

        expectH3ErrorEqual(
            error: connection.errors.first,
            expectedCode: .qpackEncoderStreamError,
            expectedH3ErrorCode: .qpackEncoderStreamError
        )
    }

    @Test func incomingDecoderInstructionIsForwardedToTheEncoder() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let encoderStream = TestOutboundEncoderStream()
        let streamID = QUICStreamID(4)

        coder.receivedRemoteSettings(maxQueueSize: 100, effectiveDynamicTableSize: 1024)
        coder.outboundEncoderStreamReady(encoderStream)
        _ = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: streamID)

        coder.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: streamID))

        #expect(connection.errors.isEmpty)
    }

    @Test func incomingDecoderInstructionWithoutDynamicTableIsAConnectionError() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)

        // We never opened an encoder stream, so the peer's decoder has nothing to acknowledge.
        coder.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: 1))

        expectH3ErrorEqual(
            error: connection.errors.first,
            expectedCode: .qpackDecoderStreamError,
            expectedH3ErrorCode: .qpackDecoderStreamError
        )
    }

    // MARK: Stream management

    @Test func requestStreamClosedCleanlySendsNothing() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        coder.outboundDecoderStreamReady(decoderStream)

        coder.requestStreamClosed(streamID: 1, seenEOF: true)

        #expect(decoderStream.instructions.isEmpty)
    }

    @Test func requestStreamClosedWhileBlockedCancelsTheStream() {
        let connection = TestConnection()
        let coder = TestCoder(decoderMaxTableSize: 1024, decoderMaxBlockedStreams: 100, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        let streamID = QUICStreamID(1)

        coder.outboundDecoderStreamReady(decoderStream)
        coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))

        // Block the stream on an entry we haven't received yet.
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
                lines: [.indexedWithPostBase(index: 0)]
            )
        )
        coder.decodeHeaders(headers, streamID: streamID, decodeReceiver: receiver)
        #expect(receiver.results.isEmpty)

        // The stream goes away before we could decode. The peer's encoder must be told not to expect an
        // acknowledgement for the field sections it sent on this stream. See RFC 9204 § 2.2.2.2.
        coder.requestStreamClosed(streamID: streamID, seenEOF: false)
        #expect(decoderStream.instructions == [.streamCancellation(streamID: streamID)])
        decoderStream.instructions.removeAll()

        // The entry finally arrives. The pending decode is gone, so the receiver is never called.
        coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))
        #expect(receiver.results.isEmpty)
        #expect(decoderStream.instructions == [.insertCountIncrement(increment: 1)])
    }
}

// MARK: - Test doubles

private typealias TestCoder = QPACKCoder<
    TestOutboundEncoderStream,
    TestOutboundDecoderStream,
    TestConnection,
    TestDecodeReceiver
>

/// Records the encoder instructions the coder wants to send to the peer's decoder.
private final class TestOutboundEncoderStream: QPACKOutboundEncoderStream {
    var instructions: [QPACKEncoderInstruction] = []

    func sendInstructions(_ instructions: some Collection<QPACKEncoderInstruction>) {
        self.instructions.append(contentsOf: instructions)
    }
}

/// Records the decoder instructions the coder wants to send to the peer's encoder.
private final class TestOutboundDecoderStream: QPACKOutboundDecoderStream {
    var instructions: [QPACKDecoderInstruction] = []

    func sendInstruction(_ instruction: QPACKDecoderInstruction) {
        self.instructions.append(instruction)
    }

    func sendInstructions(_ instructions: some Collection<QPACKDecoderInstruction>) {
        self.instructions.append(contentsOf: instructions)
    }
}

/// Records the connection level side effects: errors and requests to open an encoder stream.
private final class TestConnection: HTTP3.ConnectionDelegate {
    var errors: [HTTP3Error] = []
    var madeOutboundEncoderStreamCount = 0

    func connectionError(_ error: HTTP3Error) {
        self.errors.append(error)
    }

    func makeOutboundEncoderStream() {
        self.madeOutboundEncoderStreamCount += 1
    }
}

/// Records the decode results delivered to a single stream.
private final class TestDecodeReceiver: QPACKDecodeReceiver {
    var results: [Result<[HTTPField], any Error>] = []

    /// The fields from all successful decodes, in order.
    var decodedFields: [[HTTPField]] {
        self.results.compactMap {
            switch $0 {
            case .success(let fields): return fields
            case .failure: return nil
            }
        }
    }

    /// The errors from all failed decodes, in order.
    var errors: [any Error] {
        self.results.compactMap {
            switch $0 {
            case .success: return nil
            case .failure(let error): return error
            }
        }
    }

    func decodeResult(_ result: Result<[HTTPField], any Error>) {
        self.results.append(result)
    }
}
