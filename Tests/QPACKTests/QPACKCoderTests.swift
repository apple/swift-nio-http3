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
import Testing

@_spi(PackageInternal) @testable import QPACK

/// Tests for ``QPACKCoder``.
///
/// The coder is a thin layer over ``QPACKStateMachine``, routing its actions to the outbound streams, the
/// connection and the decode receivers. The state machine itself is covered by ``QPACKStateMachineTests``, so
/// these tests are about the routing.
struct QPACKCoderTests {

    /// Make a coder with limits that are large enough not to matter. Override only what a test is about.
    @available(anyAppleOS 27, *)
    private static func makeTestCoder(
        encoderMaxTableSize: Int = 1024,
        decoderMaxTableSize: Int = 1024,
        decoderMaxBlockedStreams: Int = 100,
        errorDelegate: TestConnection
    ) -> TestCoder {
        TestCoder(
            encoderMaxTableSize: encoderMaxTableSize,
            decoderMaxTableSize: decoderMaxTableSize,
            decoderMaxBlockedStreams: decoderMaxBlockedStreams,
            errorDelegate: errorDelegate
        )
    }

    // MARK: Remote settings

    @available(anyAppleOS 27, *)
    @Test func remoteSettingsWithDynamicTableAsksForEncoderStream() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 1024)

        #expect(connection.madeOutboundEncoderStreamCount == 1)
    }

    @available(anyAppleOS 27, *)
    @Test func remoteSettingsWithoutDynamicTableDoesNotAskForEncoderStream() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        // RFC 9204 § 4.2: An endpoint MAY avoid creating an encoder stream if it will not be used.
        try coder.receivedRemoteSettings(maxQueueSize: 0, peersDynamicTableSize: 0)

        #expect(connection.madeOutboundEncoderStreamCount == 0)
    }

    @available(anyAppleOS 27, *)
    @Test func remoteSettingsAreCappedByTheLocalEncoderTableSize() throws {
        let connection = TestConnection()
        // The peer offers a bigger table than this endpoint is willing to keep for its own encoder.
        let coder = Self.makeTestCoder(encoderMaxTableSize: 300, errorDelegate: connection)

        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 4096)
        #expect(connection.madeOutboundEncoderStreamCount == 1)

        let encoderStream = TestOutboundEncoderStream()
        coder.outboundEncoderStreamReady(encoderStream)

        // The smaller of the two limits wins, not the peer's.
        #expect(encoderStream.instructions == [.setDynamicTableCapacity(300)])
    }

    @available(anyAppleOS 27, *)
    @Test func remoteSettingsWithoutALocalEncoderTableDoesNotAskForEncoderStream() throws {
        let connection = TestConnection()
        // This endpoint refuses the dynamic table for its own encoder, whatever the peer offers.
        let coder = Self.makeTestCoder(encoderMaxTableSize: 0, errorDelegate: connection)

        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 4096)

        #expect(connection.madeOutboundEncoderStreamCount == 0)

        // With no encoder stream the coder must stay on the static encoder: it holds no stream to write
        // instructions to, and would trap.
        let headers = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: 1)
        #expect(
            headers.lines == [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 5,
                    value: "test"
                )
            ]
        )
    }

    @available(anyAppleOS 27, *)
    @Test func secondRemoteSettingsIsAConnectionError() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 300)
        #expect(connection.madeOutboundEncoderStreamCount == 1)

        // RFC 9114 § 7.2.4: the peer may only send SETTINGS once.
        #expect(throws: QPACKError.duplicateSettings) {
            try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 4096)
        }

        // The first settings still stand: no second encoder stream, and the table keeps its original size.
        #expect(connection.madeOutboundEncoderStreamCount == 1)
        let encoderStream = TestOutboundEncoderStream()
        coder.outboundEncoderStreamReady(encoderStream)
        #expect(encoderStream.instructions == [.setDynamicTableCapacity(300)])
    }

    @available(anyAppleOS 27, *)
    @Test func secondRemoteSettingsWithoutDynamicTableIsAConnectionError() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        try coder.receivedRemoteSettings(maxQueueSize: 0, peersDynamicTableSize: 0)
        #expect(connection.madeOutboundEncoderStreamCount == 0)

        // The peer can't change its mind about the dynamic table by sending SETTINGS again.
        #expect(throws: QPACKError.duplicateSettings) {
            try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 300)
        }

        #expect(connection.madeOutboundEncoderStreamCount == 0)
    }

    // MARK: Encoder stream

    @available(anyAppleOS 27, *)
    @Test func outboundEncoderStreamReadySendsTableCapacity() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 300)
        #expect(connection.madeOutboundEncoderStreamCount == 1)

        let encoderStream = TestOutboundEncoderStream()
        coder.outboundEncoderStreamReady(encoderStream)

        #expect(encoderStream.instructions == [.setDynamicTableCapacity(300)])
    }

    // MARK: Encode

    @available(anyAppleOS 27, *)
    @Test func encodeHeadersWithoutDynamicTableSendsNoInstructions() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        // No remote settings yet, so the static encoder must be used. Note there is no encoder stream set on the
        // coder at all here: if it tried to send an instruction it would trap.
        let headers = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: 1)

        #expect(
            headers.lines == [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 5,
                    value: "test"
                )
            ]
        )
    }

    @available(anyAppleOS 27, *)
    @Test func encodeHeadersWhileAwaitingEncoderStreamSendsNoInstructions() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        // The peer permits the dynamic table, so an encoder stream has been requested, but it isn't here yet. The
        // coder must stay on the static encoder: it holds no stream to write instructions to, and would trap.
        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 300)
        #expect(connection.madeOutboundEncoderStreamCount == 1)

        let headers = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: 1)

        #expect(
            headers.lines == [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 5,
                    value: "test"
                )
            ]
        )
    }

    @available(anyAppleOS 27, *)
    @Test func encodeHeadersWithDynamicTableForwardsInstructions() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let encoderStream = TestOutboundEncoderStream()

        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 300)
        coder.outboundEncoderStreamReady(encoderStream)
        #expect(encoderStream.instructions == [.setDynamicTableCapacity(300)])
        encoderStream.instructions.removeAll()

        let headers = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: 1)

        // The entry was inserted into the dynamic table, so the peer's decoder needs to be told about it.
        #expect(encoderStream.instructions == [.insertWithNameReference(.staticTable, relativeIndex: 5, value: "test")])
        #expect(
            headers
                == FieldSection(
                    prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 300),
                    lines: [.indexedWithPostBase(index: 0)]
                )
        )
    }

    // MARK: Decoder stream

    @available(anyAppleOS 27, *)
    @Test func outboundDecoderStreamReadyFlushesBufferedInstructions() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        // The peer inserts an entry before our decoder stream exists, so the acknowledgement must be buffered.
        try coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))
        try coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))

        let decoderStream = TestOutboundDecoderStream()
        coder.outboundDecoderStreamReady(decoderStream)
        #expect(decoderStream.instructions == [.insertCountIncrement(increment: 1)])
    }

    @available(anyAppleOS 27, *)
    @Test func outboundDecoderStreamReadyWithNothingBuffered() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        let decoderStream = TestOutboundDecoderStream()
        coder.outboundDecoderStreamReady(decoderStream)
        #expect(decoderStream.instructions.isEmpty)
    }

    // MARK: Decode

    @available(anyAppleOS 27, *)
    @Test func decodeHeadersDeliversResultSynchronously() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        coder.outboundDecoderStreamReady(decoderStream)

        let headers = FieldSection(
            prefix: .init(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [.literal(requireLiteralRepresentation: false, name: "cookie", value: "test")]
        )
        coder.decodeFields(headers, streamID: 0, decodeReceiver: receiver)

        #expect(receiver.decodedFields == [[.init(name: .cookie, value: "test")]])
        // A field section which only uses the static table needs no acknowledgement.
        #expect(decoderStream.instructions.isEmpty)
    }

    @available(anyAppleOS 27, *)
    @Test func decodeHeadersSendsSectionAcknowledgement() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        let streamID = QUICStreamID(0)

        coder.outboundDecoderStreamReady(decoderStream)
        try coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))
        try coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))
        #expect(decoderStream.instructions == [.insertCountIncrement(increment: 1)])
        decoderStream.instructions.removeAll()

        let headers = FieldSection(
            prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
            lines: [.indexedWithPostBase(index: 0)]
        )
        coder.decodeFields(headers, streamID: streamID, decodeReceiver: receiver)

        #expect(receiver.decodedFields == [[.init(name: .cookie, value: "test")]])
        // The field section referenced the dynamic table, so the peer's encoder must be acknowledged.
        #expect(decoderStream.instructions == [.sectionAcknowledgement(streamID: streamID)])
    }

    @available(anyAppleOS 27, *)
    @Test func blockedDecodeIsDeliveredOnceUnblocked() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        let streamID = QUICStreamID(0)

        coder.outboundDecoderStreamReady(decoderStream)
        try coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))

        // This field section references an entry we haven't been told about yet, so the stream becomes blocked.
        let headers = FieldSection(
            prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
            lines: [.indexedWithPostBase(index: 0)]
        )
        coder.decodeFields(headers, streamID: streamID, decodeReceiver: receiver)
        #expect(receiver.results.isEmpty)

        // The missing entry arrives, which unblocks the decode.
        try coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))

        #expect(receiver.decodedFields == [[.init(name: .cookie, value: "test")]])
        #expect(
            decoderStream.instructions == [
                .insertCountIncrement(increment: 1),
                .sectionAcknowledgement(streamID: streamID),
            ]
        )
    }

    @available(anyAppleOS 27, *)
    @Test func oneInstructionUnblocksAllWaitingStreams() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()

        coder.outboundDecoderStreamReady(decoderStream)
        try coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))

        // Three streams all block on the very same missing entry.
        let headers = FieldSection(
            prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
            lines: [.indexedWithPostBase(index: 0)]
        )
        let streamIDs: [QUICStreamID] = [0, 4, 8]
        let receivers = streamIDs.map { streamID -> TestDecodeReceiver in
            let receiver = TestDecodeReceiver()
            coder.decodeFields(headers, streamID: streamID, decodeReceiver: receiver)
            #expect(receiver.results.isEmpty)
            return receiver
        }

        // One instruction supplies the entry all three were waiting for.
        try coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))

        for receiver in receivers {
            #expect(receiver.decodedFields == [[.init(name: .cookie, value: "test")]])
        }
        // Ack order is unspecified: pending decodes sit in a heap keyed on required insert count, and these tie.
        #expect(decoderStream.instructions.first == .insertCountIncrement(increment: 1))
        #expect(
            Set(decoderStream.instructions.dropFirst())
                == Set(streamIDs.map { .sectionAcknowledgement(streamID: $0) })
        )
    }

    @available(anyAppleOS 27, *)
    @Test func streamsBlockedOnDifferentInsertCountsUnblockInOrder() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()

        coder.outboundDecoderStreamReady(decoderStream)
        try coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))

        // Stream 4 needs two entries, stream 0 needs only the first.
        func headers(requiredInsertCount: Int) -> FieldSection {
            FieldSection(
                prefix: FieldSectionPrefix(requiredInsertCount: requiredInsertCount, base: 0)
                    .encode(maxCapacity: 1024),
                lines: [.indexedWithPostBase(index: requiredInsertCount - 1)]
            )
        }
        let receiver0 = TestDecodeReceiver()
        let receiver4 = TestDecodeReceiver()
        coder.decodeFields(headers(requiredInsertCount: 2), streamID: 4, decodeReceiver: receiver4)
        coder.decodeFields(headers(requiredInsertCount: 1), streamID: 0, decodeReceiver: receiver0)

        // The first entry only unblocks stream 0.
        try coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "one"))
        #expect(receiver0.decodedFields == [[.init(name: .cookie, value: "one")]])
        #expect(receiver4.results.isEmpty)

        // The second entry unblocks stream 4.
        try coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "two"))
        #expect(receiver4.decodedFields == [[.init(name: .cookie, value: "two")]])
        #expect(receiver0.results.count == 1)
    }

    @available(anyAppleOS 27, *)
    @Test func decodeStreamErrorOnlyFailsTheStream() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        coder.outboundDecoderStreamReady(decoderStream)

        // This decodes fine, but an uppercase field name is a malformed message: a stream level error.
        let headers = FieldSection(
            prefix: FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 0),
            lines: [.literal(requireLiteralRepresentation: false, name: "ILLEGAL", value: "value")]
        )
        coder.decodeFields(headers, streamID: 0, decodeReceiver: receiver)

        #expect(receiver.results.count == 1)
        #expect(receiver.errors.first == .decodeError(.invalidHeaderName))
        // A stream level error must not take down the connection.
        #expect(receiver.errors.first?.isConnectionError == false)
    }

    @available(anyAppleOS 27, *)
    @Test func decodeConnectionErrorIsGivenToTheStream() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        coder.outboundDecoderStreamReady(decoderStream)

        // A reference to a dynamic table entry which doesn't exist is a connection error.
        let headers = FieldSection(
            prefix: FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 100),
            lines: [.indexedWithPostBase(index: 0)]
        )
        coder.decodeFields(headers, streamID: 0, decodeReceiver: receiver)

        // The stream escalates the failure to the connection, so it is the only one to hear of it.
        #expect(receiver.errors == [.decodeError(.invalidReference)])
        #expect(receiver.errors.first?.isConnectionError == true)
    }

    @available(anyAppleOS 27, *)
    @Test func invalidFieldSectionPrefixIsAConnectionError() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        coder.outboundDecoderStreamReady(decoderStream)

        // RFC 9204 § 4.5.1.1: an EncodedInsertCount which no conformant encoder could have produced is a
        // connection error of type QPACK_DECOMPRESSION_FAILED.
        let headers = FieldSection(
            prefix: .init(encodedRequiredInsertCount: 200, deltaBase: 100, signBit: true),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "test")]
        )
        coder.decodeFields(headers, streamID: 0, decodeReceiver: receiver)

        #expect(receiver.errors == [.invalidFieldSectionPrefix])
    }

    @available(anyAppleOS 27, *)
    @Test func tooManyBlockedStreamsIsAConnectionError() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(decoderMaxBlockedStreams: 1, errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        coder.outboundDecoderStreamReady(decoderStream)

        let headers = FieldSection(
            prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 1024),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "test")]
        )

        // We promised to support one blocked stream, so the first one is simply queued.
        let receiver1 = TestDecodeReceiver()
        coder.decodeFields(headers, streamID: 1, decodeReceiver: receiver1)
        #expect(receiver1.results.isEmpty)

        // RFC 9204 § 2.1.2: more blocked streams than promised is a connection error.
        let receiver2 = TestDecodeReceiver()
        coder.decodeFields(headers, streamID: 2, decodeReceiver: receiver2)
        #expect(receiver2.errors == [.tooManyBlockedStreams])
        #expect(receiver1.results.isEmpty)
    }

    // MARK: Incoming instructions

    @available(anyAppleOS 27, *)
    @Test func invalidIncomingEncoderInstructionIsAConnectionError() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        // Invalid because it exceeds the capacity we advertised.
        #expect(throws: QPACKError.invalidEncoderInstruction) {
            try coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1025))
        }
    }

    @available(anyAppleOS 27, *)
    @Test func incomingDecoderInstructionIsForwardedToTheEncoder() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let encoderStream = TestOutboundEncoderStream()
        let streamID = QUICStreamID(4)

        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 1024)
        coder.outboundEncoderStreamReady(encoderStream)
        _ = coder.encodeHeaders([.init(name: .cookie, value: "test")], streamID: streamID)

        try coder.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: streamID))

    }

    @available(anyAppleOS 27, *)
    @Test func incomingDecoderInstructionWithoutDynamicTableIsAConnectionError() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)

        // We never opened an encoder stream, so the peer's decoder has nothing to acknowledge.
        #expect(throws: QPACKError.decoderInstructionWithoutDynamicTable) {
            try coder.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: 1))
        }
    }

    // MARK: Stream management

    @available(anyAppleOS 27, *)
    @Test func requestStreamClosedCleanlySendsNothing() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        coder.outboundDecoderStreamReady(decoderStream)

        coder.requestStreamClosed(streamID: 1, seenEOF: true)

        #expect(decoderStream.instructions.isEmpty)
    }

    @available(anyAppleOS 27, *)
    @Test func requestStreamClosedWhileBlockedCancelsTheStream() throws {
        let connection = TestConnection()
        let coder = Self.makeTestCoder(errorDelegate: connection)
        let decoderStream = TestOutboundDecoderStream()
        let receiver = TestDecodeReceiver()
        let streamID = QUICStreamID(1)

        coder.outboundDecoderStreamReady(decoderStream)
        try coder.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(1024))

        // Block the stream on an entry we haven't received yet.
        let headers = FieldSection(
            prefix: FieldSectionPrefix(requiredInsertCount: 1, base: 0).encode(maxCapacity: 100),
            lines: [.indexedWithPostBase(index: 0)]
        )
        coder.decodeFields(headers, streamID: streamID, decodeReceiver: receiver)
        #expect(receiver.results.isEmpty)

        // The stream goes away before we could decode. The peer's encoder must be told not to expect an
        // acknowledgement for the field sections it sent on this stream. See RFC 9204 § 2.2.2.2.
        coder.requestStreamClosed(streamID: streamID, seenEOF: false)
        #expect(decoderStream.instructions == [.streamCancellation(streamID: streamID)])
        decoderStream.instructions.removeAll()

        // The entry finally arrives. The pending decode is gone, so the receiver is never called.
        try coder.receivedIncomingEncoderInstruction(.insertWithLiteralName(name: "cookie", value: "test"))
        #expect(receiver.results.isEmpty)
        #expect(decoderStream.instructions == [.insertCountIncrement(increment: 1)])
    }
}

// MARK: - Test doubles

@available(anyAppleOS 27, *)
private typealias TestCoder = QPACKCoder<
    TestOutboundEncoderStream,
    TestOutboundDecoderStream,
    TestConnection,
    TestDecodeReceiver
>

/// Records the encoder instructions the coder wants to send to the peer's decoder.
@available(anyAppleOS 27, *)
private final class TestOutboundEncoderStream: QPACKOutboundEncoderStream {
    var instructions: [QPACKEncoderInstruction] = []

    func sendInstructions(_ instructions: some Collection<QPACKEncoderInstruction>) {
        self.instructions.append(contentsOf: instructions)
    }
}

/// Records the decoder instructions the coder wants to send to the peer's encoder.
@available(anyAppleOS 27, *)
private final class TestOutboundDecoderStream: QPACKOutboundDecoderStream {
    var instructions: [QPACKDecoderInstruction] = []

    func sendInstruction(_ instruction: QPACKDecoderInstruction) {
        self.instructions.append(instruction)
    }

    func sendInstructions(_ instructions: some Collection<QPACKDecoderInstruction>) {
        self.instructions.append(contentsOf: instructions)
    }
}

/// Records the requests to open an encoder stream.
private final class TestConnection: QPACKConnectionDelegate {
    var madeOutboundEncoderStreamCount = 0

    func makeOutboundEncoderStream() {
        self.madeOutboundEncoderStreamCount += 1
    }
}

/// Records the decode results delivered to a single stream.
@available(anyAppleOS 27, *)
private final class TestDecodeReceiver: QPACKDecodeReceiver {
    var results: [Result<[HTTPField], QPACKError>] = []

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
    var errors: [QPACKError] {
        self.results.compactMap {
            switch $0 {
            case .success: return nil
            case .failure(let error): return error
            }
        }
    }

    func decodeResult(_ result: Result<[HTTPField], QPACKError>) {
        self.results.append(result)
    }
}
