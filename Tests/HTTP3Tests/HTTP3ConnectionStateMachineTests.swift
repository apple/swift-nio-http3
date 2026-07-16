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

struct HTTP3ConnectionStateMachineTests {
    // MARK: Initialization

    @Test
    func testInitialize() {
        let testSettings = HTTP3Settings()
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)
        let action = stateMachine.initialize()
        #expect(action == .createControlStream)
    }

    @Test
    func testInitializeWithQPACK() {
        let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)
        let action = stateMachine.initialize()
        #expect(action == .createControlAndDecoderStreams)
    }

    @Test
    func testInitializeAfterFinish() {
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .client)
        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)
        #expect(stateMachine.initialize() == nil)
    }

    // MARK: Inbound streams

    @Test
    func testInboundControlStream() {
        let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlAndDecoderStreams)

        let action2 = stateMachine.inboundControlStreamReceived(streamID: 3)
        guard case .addHandlers = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
    }

    @Test
    func testInboundControlStreamAfterShutdown() {
        let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlAndDecoderStreams)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action2 = stateMachine.inboundControlStreamReceived(streamID: 3)
        guard case .emitStreamError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .H3_STREAM_CREATION_ERROR)
    }

    @Test
    func testDoubleInboundControlStream() {
        let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlAndDecoderStreams)

        let action2 = stateMachine.inboundControlStreamReceived(streamID: 3)
        guard case .addHandlers = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }

        let action3 = stateMachine.inboundControlStreamReceived(streamID: 7)
        guard case .emitConnectionError(let error) = action3 else {
            Issue.record("Unexpected action \(action3)")
            return
        }
        error.expect(code: .invalidStream, h3ErrorCode: .H3_STREAM_CREATION_ERROR)
    }

    @Test
    func testInboundPushStreamOnServer() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action = stateMachine.inboundPushStreamReceived(streamID: idGenerator.inboundUni())
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .H3_STREAM_CREATION_ERROR)
    }

    @Test
    func testInboundPushStreamOnClient() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action = stateMachine.inboundPushStreamReceived(streamID: idGenerator.inboundUni())
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .H3_ID_ERROR)
    }

    @Test
    func testInboundPushStreamAfterShutdown() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action = stateMachine.inboundPushStreamReceived(streamID: idGenerator.inboundUni())
        guard case .emitStreamError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .H3_STREAM_CREATION_ERROR)
    }

    @Test
    func testInboundQPACKEncoderStream() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action = stateMachine.inboundQPACKEncoderStreamReceived(streamID: idGenerator.inboundUni())
        guard case .addHandlers = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
    }

    @Test
    func testDoubleInboundQPACKEncoderStream() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action1 = stateMachine.inboundQPACKEncoderStreamReceived(streamID: idGenerator.inboundUni())
        guard case .addHandlers = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }

        let action2 = stateMachine.inboundQPACKEncoderStreamReceived(streamID: idGenerator.inboundUni())
        guard case .emitConnectionError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .invalidStream, h3ErrorCode: .H3_STREAM_CREATION_ERROR)
    }

    @Test
    func testInboundQPACKEncoderStreamAfterShutdown() {
        let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        _ = stateMachine.shutdownConnectionImmediately()

        let action1 = stateMachine.inboundQPACKEncoderStreamReceived(streamID: 2)
        guard case .emitStreamError(let error) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .streamCreationError,
            expectedH3ErrorCode: .H3_STREAM_CREATION_ERROR
        )
    }

    @Test
    func testInboundQPACKDecoderStream() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action = stateMachine.inboundQPACKDecoderStreamReceived(streamID: idGenerator.inboundUni())
        guard case .addHandlers = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
    }

    @Test
    func testDoubleInboundQPACKDecoderStream() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action1 = stateMachine.inboundQPACKDecoderStreamReceived(streamID: idGenerator.inboundUni())
        guard case .addHandlers = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }

        let action2 = stateMachine.inboundQPACKDecoderStreamReceived(streamID: idGenerator.inboundUni())
        guard case .emitConnectionError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .invalidStream, h3ErrorCode: .H3_STREAM_CREATION_ERROR)
    }

    @Test
    func testInboundQPACKDecoderStreamAfterShutdown() {
        let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        _ = stateMachine.shutdownConnectionImmediately()

        let action1 = stateMachine.inboundQPACKDecoderStreamReceived(streamID: 2)
        guard case .emitStreamError(let error) = action1 else {
            Issue.record("Unexpected action \(action1)")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .streamCreationError,
            expectedH3ErrorCode: .H3_STREAM_CREATION_ERROR
        )
    }

    @Test
    func testInboundRequestStreamOnServer() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action2 = stateMachine.inboundRequestStreamReceived(streamID: idGenerator.inboundBidi())
        guard case .addHandlers = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
    }

    @Test
    func testInboundRequestStreamOnClient() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action2 = stateMachine.inboundRequestStreamReceived(streamID: idGenerator.inboundBidi())
        guard case .emitConnectionError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }

        error.expect(code: .streamCreationError, h3ErrorCode: .H3_STREAM_CREATION_ERROR)
    }

    @Test
    func testInboundRequestStreamAfterShutdown() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action2 = stateMachine.inboundRequestStreamReceived(streamID: idGenerator.inboundBidi())
        guard case .emitStreamError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .H3_STREAM_CREATION_ERROR)
    }

    @Test
    func testInboundRequestStreamAfterGoawayWithHigherID() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action2 = stateMachine.sendGoaway(goawayID: 12)
        guard case .sendGoaway = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }

        let action3 = stateMachine.inboundRequestStreamReceived(streamID: 12)
        guard case .emitStreamError(let error) = action3 else {
            Issue.record("Unexpected action \(action3)")
            return
        }
        expectH3ErrorEqual(error: error, expectedCode: .rejected, expectedH3ErrorCode: .H3_REQUEST_REJECTED)
    }

    @Test
    func testInboundUnknownStream() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action = stateMachine.inboundUnknownStreamReceived(
            streamID: idGenerator.inboundUni(),
            streamType: .unknown(raw: 100)
        )
        guard case .emitStreamError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .streamCreationError,
            expectedH3ErrorCode: .H3_STREAM_CREATION_ERROR,
            expectedMessage: "Rejecting inbound stream of unknown type 100"
        )
    }

    @Test
    func testInboundUnknownStreamAfterShutdown() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action1 = stateMachine.sendGoaway(goawayID: 12)
        guard case .sendGoaway = action1 else {
            Issue.record("Unexpected action \(String(describing: action1))")
            return
        }

        let action2 = stateMachine.inboundUnknownStreamReceived(
            streamID: idGenerator.inboundUni(),
            streamType: .unknown(raw: 100)
        )
        guard case .emitStreamError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .streamCreationError,
            expectedH3ErrorCode: .H3_STREAM_CREATION_ERROR,
            expectedMessage: "Rejecting inbound stream of unknown type 100"
        )
    }

    // MARK: Settings

    @Test
    func testGotSettingsNoQPACK() {
        let remoteSettings = HTTP3Settings(qpackMaximumTableCapacity: 0)
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .client)
        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)
        let action2 = stateMachine.receivedControlFrame(.settings(remoteSettings))
        #expect(action2 == nil)
    }

    @Test
    func testGotSettingsWithQPACK() {
        let localSettings = HTTP3Settings(qpackMaximumTableCapacity: 200)
        let remoteSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: localSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlAndDecoderStreams)

        let action2 = stateMachine.receivedControlFrame(.settings(remoteSettings))
        guard case .makeEncoderInstructionStream = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }

        let action3 = stateMachine.outboundEncoderStreamReady(streamID: 3)
        #expect(action3 == .sendEncoderInstruction(.setDynamicTableCapacity(100)))
    }

    @Test
    func testGotSettingsAfterShutdown() {
        let remoteSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action2 = stateMachine.receivedControlFrame(.settings(remoteSettings))
        #expect(action2 == nil)
    }

    // MARK: GOAWAY

    @Test
    func testGotGoawayWithNoStreams() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action = stateMachine.receivedControlFrame(.goaway(4))
        // There are no streams so we immediately close
        guard case .closeConnection = action else {
            Issue.record("Unexpected action \(String(describing: action))")
            return
        }
    }

    @Test(arguments: [
        1 as HTTP3GoawayID,  // Server-initiated bidi
        2,  // Client-initiated uni
        3,  // Server-initiated uni
    ])
    // Note: Theres no such thing as an invalid ID on the server. Because the server takes push ids, not stream ids, and those can be any number.
    func testGotGoawayWithInvalidIDOnClient(testID: HTTP3GoawayID) {
        let remoteSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

        // We must always get settings before anything else on the control stream
        _ = stateMachine.receivedControlFrame(.settings(remoteSettings))

        let action = stateMachine.receivedControlFrame(.goaway(testID))
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action \(String(describing: action))")
            return
        }
        expectH3ErrorEqual(
            error: error,
            expectedCode: .invalidGoawayStreamID,
            expectedH3ErrorCode: .H3_ID_ERROR
        )
    }

    @Test
    func testGotGoawayOnServerDoesNothing() {
        let remoteSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .server)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

        // We must always get settings before anything else on the control stream
        _ = stateMachine.receivedControlFrame(.settings(remoteSettings))

        let action2 = stateMachine.receivedControlFrame(.goaway(0))
        #expect(action2 == nil)  // Does nothing for now..because we haven't implemented push
    }

    @Test
    func testGotGoawayCancelsStream() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        // Let's say we have some request streams already
        stateMachine.outboundRequestStreamReady(streamID: 0)
        stateMachine.outboundRequestStreamReady(streamID: 4)
        stateMachine.outboundRequestStreamReady(streamID: 8)

        // And then get a goaway with id 4. It should cancel the streams >= that id
        let action2 = stateMachine.receivedControlFrame(.goaway(4))
        guard case .cancelStreams(let idsToCancel) = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }
        #expect(idsToCancel.sorted() == [4, 8])

        // Those streams got cancelled successfuly
        let action3 = stateMachine.streamClosed(streamID: 8, seenEOF: true, streamType: .request)
        let action4 = stateMachine.streamClosed(streamID: 4, seenEOF: true, streamType: .request)

        guard case .none = action3 else {
            Issue.record("Unexpected action \(String(describing: action3))")
            return
        }
        guard case .none = action4 else {
            Issue.record("Unexpected action \(String(describing: action4))")
            return
        }

        // Another goaway with the same id doesn't require cancelling any further streams
        let action5 = stateMachine.receivedControlFrame(.goaway(4))
        guard case .none = action5 else {
            Issue.record("Unexpected action \(String(describing: action5))")
            return
        }

        // Closing the last stream will shut the connection.
        let action6 = stateMachine.streamClosed(streamID: 0, seenEOF: true, streamType: .request)
        guard case .closeConnection = action6 else {
            Issue.record("Unexpected action \(String(describing: action6))")
            return
        }
    }

    /// When the server sends a goaway, we should explicitly cancel streams above that ID
    @Test
    func testSendGoawayCancelsStream() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        // Let's say we have some request streams already
        _ = stateMachine.inboundRequestStreamReceived(streamID: 0)
        _ = stateMachine.inboundRequestStreamReceived(streamID: 4)
        _ = stateMachine.inboundRequestStreamReceived(streamID: 8)

        // And then send a goaway with id 4. It should cancel the streams >= that id
        let action2 = stateMachine.sendGoaway(goawayID: 4)
        guard case .sendGoaway(let idToSend, let idsToCancel) = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }
        #expect(idToSend == 4)
        #expect(idsToCancel.sorted() == [4, 8])

        // Those streams got cancelled successfuly
        let action3 = stateMachine.streamClosed(streamID: 8, seenEOF: true, streamType: .request)
        let action4 = stateMachine.streamClosed(streamID: 4, seenEOF: true, streamType: .request)

        guard case .none = action3 else {
            Issue.record("Unexpected action \(String(describing: action3))")
            return
        }
        guard case .none = action4 else {
            Issue.record("Unexpected action \(String(describing: action4))")
            return
        }

        // Another goaway with the same id doesn't require cancelling any further streams
        let action5 = stateMachine.receivedControlFrame(.goaway(4))
        guard case .none = action5 else {
            Issue.record("Unexpected action \(String(describing: action5))")
            return
        }

        // Closing the last stream will shut the connection because the client has exhausted all possible ids below the goaway.
        let action6 = stateMachine.streamClosed(streamID: 0, seenEOF: true, streamType: .request)
        guard case .closeConnection = action6 else {
            Issue.record("Unexpected action \(String(describing: action6))")
            return
        }
    }

    // MARK: Push

    @Test
    func testMaxPushIDOnServer() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        // TODO: https://github.com/apple/swift-nio-http3/issues/1
        // For now, push related frames are dropped.
        #expect(stateMachine.receivedControlFrame(.maxPushID(1)) == nil)
    }

    @Test
    func testMaxPushIDOnClient() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        // A client MUST treat the receipt of a MAX_PUSH_ID frame as a connection error of type H3_FRAME_UNEXPECTED.
        let action = stateMachine.receivedControlFrame(.maxPushID(1))
        switch action {
        case .emitConnectionError(let error):
            expectH3ErrorEqual(error: error, expectedCode: .unexpectedFrame, expectedH3ErrorCode: .H3_FRAME_UNEXPECTED)
        default:
            Issue.record("Unexpected action: \(String(describing: action))")
        }
    }

    @Test(arguments: [HTTP3ConnectionType.server, .client])
    func testCancelPush(type: HTTP3ConnectionType) {
        var idGenerator = IDGenerator(type: type)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: type, idGenerator: &idGenerator)

        // TODO: https://github.com/apple/swift-nio-http3/issues/1
        // For now, push related frames are dropped.
        #expect(stateMachine.receivedControlFrame(.cancelPush(1)) == nil)
    }

    // MARK: Outbound streams

    @Test
    func testOutboundRequestStreamFromClient() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action2 = stateMachine.outboundRequestStreamRequested()
        guard case .create = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
    }

    @Test
    func testOutboundRequestStreamFromServer() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action2 = stateMachine.outboundRequestStreamRequested()
        guard case .failedToCreateStream(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: nil)
    }

    @Test
    func testOutboundRequestStreamAfterShutdown() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action2 = stateMachine.outboundRequestStreamRequested()
        guard case .failedToCreateStream(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: nil)
    }

    @Test
    func testOutboundRequestStreamAfteReceiveGoaway() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        _ = stateMachine.receivedControlFrame(.goaway(0))

        let action2 = stateMachine.outboundRequestStreamRequested()
        guard case .failedToCreateStream(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: nil)
    }

    // MARK: QPACK

    @Test
    func testIncomingEncoderInstructionWithQueue() {
        let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlAndDecoderStreams)

        let action2 = stateMachine.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(100))
        #expect(action2?.decoderInstructions == nil)

        let action3 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "hello", value: "world")
        )
        // No action yet because the stream isn't ready
        #expect(action3?.decoderInstructions == nil)

        let action4 = stateMachine.outboundDecoderStreamReady(streamID: 2)
        // Now the instructions come out
        #expect(action4 == .sendDecoderInstructions([.insertCountIncrement(increment: 1)]))
    }

    @Test
    func testIncomingEncoderInstructionNoQueue() {
        let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlAndDecoderStreams)

        let action2 = stateMachine.outboundDecoderStreamReady(streamID: 3)
        #expect(action2 == nil)

        let action3 = stateMachine.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(100))
        #expect(action3?.decoderInstructions == nil)

        let action4 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "hello", value: "world")
        )
        // The instructions come out immediately because the stream is already ready
        #expect(action4?.decoderInstructions == .insertCountIncrement(increment: 1))
    }

    @Test
    func testIncomingEncoderInstructionAfterShutdown() {
        let testSettings: HTTP3Settings = .init(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlAndDecoderStreams)

        let action2 = stateMachine.outboundDecoderStreamReady(streamID: 3)
        #expect(action2 == nil)

        let action3 = stateMachine.receivedIncomingEncoderInstruction(.setDynamicTableCapacity(100))
        #expect(action3?.decoderInstructions == nil)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action4 = stateMachine.receivedIncomingEncoderInstruction(
            .insertWithLiteralName(name: "hello", value: "world")
        )
        #expect(action4 == nil)
    }

    @Test
    func testIncomingDecoderInstruction() throws {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitializedWithQPACK(
            type: .server,
            idGenerator: &idGenerator
        )

        let action4 = stateMachine.inboundRequestStreamReceived(streamID: 0)
        switch action4 {
        case .emitConnectionError(let error), .emitStreamError(let error):
            throw error
        case .addHandlers:
            // We need to send an encoder instruction before we can test decoder instructions
            let action5 = stateMachine.encodeHeaders(
                [.init(name: .init("test")!, value: "hi")],
                forStream: 0
            )
            #expect(action5.fieldSection.lines.count == 1)

            let action6 = stateMachine.receivedIncomingDecoderInstruction(.insertCountIncrement(increment: 1))
            #expect(action6 == nil)
        }
    }

    @Test
    func testEncoderStreamReadyAfterShutdown() {
        let localSettings = HTTP3Settings(qpackMaximumTableCapacity: 200)
        let remoteSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)
        var stateMachine = HTTP3ConnectionStateMachine(settings: localSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlAndDecoderStreams)

        let action2 = stateMachine.receivedControlFrame(.settings(remoteSettings))
        guard case .makeEncoderInstructionStream = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action3 = stateMachine.outboundEncoderStreamReady(streamID: 2)
        #expect(action3 == nil)  // We don't send our settings because we shutdown
    }

    // MARK: Stream tests

    @Test
    func testStreamError() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)
        let testError = HTTP3Error(
            code: .invalidFramePayload,
            message: "test",
            cause: nil,
            errorCode: .H3_FRAME_ERROR,
            location: .here()
        )
        let action = stateMachine.emitConnectionErrorFromStream(error: testError)
        switch action {
        case .emitConnectionError(let emittedError):
            expectH3ErrorEqual(
                error: emittedError,
                expectedCode: .invalidFramePayload,
                expectedH3ErrorCode: .H3_FRAME_ERROR,
                expectedMessage: "test"
            )
        case .none:
            Issue.record("Unexpected action")
        }

        // Second error is dropped
        let action2 = stateMachine.emitConnectionErrorFromStream(error: testError)
        switch action2 {
        case .none:
            break  // expected
        case .emitConnectionError:
            Issue.record("Unexpected action")
        }
    }

    /// When the remote closes the connection with an error, all open bidirectional streams should be cancelled.
    @Test
    func testCaughtRemoteErrorCancelsStreams() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        // Open some request streams
        stateMachine.outboundRequestStreamReady(streamID: 0)
        stateMachine.outboundRequestStreamReady(streamID: 4)
        stateMachine.outboundRequestStreamReady(streamID: 8)

        let error = HTTP3Error(
            code: .remoteConnectionError,
            message: "remote closed connection",
            cause: nil,
            errorCode: nil,
            location: .here()
        )

        let action = stateMachine.caughtRemoteError(error)
        guard case .cancelStreams(let idsToCancel) = action else {
            Issue.record("Expected cancelStreams, got \(String(describing: action))")
            return
        }
        #expect(idsToCancel.sorted() == [0, 4, 8])
    }

    /// When there are no open streams, `caughtRemoteError` should return an empty list.
    @Test
    func testCaughtRemoteErrorNoStreams() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let error = HTTP3Error(
            code: .remoteConnectionError,
            message: "remote closed connection",
            cause: nil,
            errorCode: nil,
            location: .here()
        )

        let action = stateMachine.caughtRemoteError(error)
        guard case .cancelStreams(let idsToCancel) = action else {
            Issue.record("Expected cancelStreams, got \(String(describing: action))")
            return
        }
        #expect(idsToCancel.isEmpty)
    }

    @Test
    func testCriticalStreamClosed() {
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .server)
        let action1 = stateMachine.initialize()
        guard case .createControlStream = action1 else {
            Issue.record("Unexpected action \(String(describing: action1))")
            return
        }

        stateMachine.outboundControlStreamReady(streamID: 3)
        let action2 = stateMachine.streamClosed(streamID: 3, seenEOF: true, streamType: .unidirectional(.control))
        guard case .emitConnectionError(let connectionError) = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }
        expectH3ErrorEqual(
            error: connectionError,
            expectedCode: .criticalStreamClosed,
            expectedH3ErrorCode: .H3_CLOSED_CRITICAL_STREAM,
            expectedMessage: "The server-initiated control stream was closed"
        )
    }
}

// MARK: Test utils

extension HTTP3ConnectionStateMachine.IncomingEncoderInstructionAction {
    fileprivate var decoderInstructions: QPACKDecoderInstruction? {
        switch self {
        case .sendDecoderInstruction(let decoderInstruction): return decoderInstruction
        case .emitConnectionError: return nil
        }
    }
}

/// Keeps track of what stream ids we've already made, so we can make the next one of a given type.
struct IDGenerator {
    var type: HTTP3ConnectionType

    /// We store the highest id we've ever made for each type of stream at the index [type].
    /// The last 2 bits are what determine the type, see RFC 9000 § 2.1.
    /// So index 0 is client-initiated bidi, index 1 is server-initiated bidi, index 2 is client-initiated uni and index 3 is server-initiated uni.
    private var highestUsedID: [QUICStreamID?] = [nil, nil, nil, nil]

    init(type: HTTP3ConnectionType) {
        self.type = type
    }

    /// The next unused ID of a given type.
    mutating func nextID(type: Int) -> QUICStreamID {
        precondition(type >= 0)
        precondition(type <= 3)
        let newID: QUICStreamID
        if let lastUsed = highestUsedID[type] {
            newID = QUICStreamID(rawValue: lastUsed.rawValue + 4)
        } else {
            newID = QUICStreamID(rawValue: UInt64(type))
        }
        self.highestUsedID[type] = newID
        return newID
    }

    /// The next unused outbound unidirectional stream id.
    mutating func outboundUni() -> QUICStreamID {
        switch self.type {
        case .server:
            return self.nextID(type: 3)
        case .client:
            return self.nextID(type: 2)
        }
    }

    /// The next unused inbound unidirectional stream id.
    mutating func inboundUni() -> QUICStreamID {
        switch self.type {
        case .server:
            return self.nextID(type: 2)
        case .client:
            return self.nextID(type: 3)
        }
    }

    /// The next unused outbound bidirectional stream id.
    mutating func outboundBidi() -> QUICStreamID {
        switch self.type {
        case .server:
            return self.nextID(type: 1)
        case .client:
            return self.nextID(type: 0)
        }
    }

    /// The next unused inbound bidirectional stream id.
    mutating func inboundBidi() -> QUICStreamID {
        switch self.type {
        case .server:
            return self.nextID(type: 0)
        case .client:
            return self.nextID(type: 1)
        }
    }
}

extension HTTP3ConnectionStateMachine {
    /// Returns a state machine which has already exchanged settings with the 'remote' and created the required streams.
    /// The settings are configured to allow qpack in both directions.
    static func makeInitializedWithQPACK(
        type: HTTP3ConnectionType,
        idGenerator: inout IDGenerator
    ) -> HTTP3ConnectionStateMachine {
        let settings = HTTP3Settings(qpackMaximumTableCapacity: 1024, qpackBlockedStreams: 100)
        return self.makeInitialized(
            type: type,
            idGenerator: &idGenerator,
            localSettings: settings,
            remoteSettings: settings,
            expectLocalQPACK: true,
            expectRemoteQPACK: true
        )
    }

    /// Returns a state machine which has already exchanged settings with the 'remote' and created the required streams.
    ///
    /// - Parameters:
    ///   - type: The type of connection (client or server)
    ///   - idGenerator: For generating IDs of the streams we'll be making.
    ///   - localSettings: The settings we use for the connection.
    ///   - remoteSettings: The settings the remote 'sent' us.
    ///   - expectLocalQPACK: Whether the provided settings are supposed to enable qpack locally. This affects what assertions we run wrt the streams we create.
    ///   - expectRemoteQPACK: Whether the provided settings are supposed to enable qpack on the peer. This affects what assertions we run wrt the streams we create.
    /// - Returns: A state machine which has been initialized, created control streams both ways, and exchanged settings. Plus, QPACK streams are created if applicable.
    static func makeInitialized(
        type: HTTP3ConnectionType,
        idGenerator: inout IDGenerator,
        localSettings: HTTP3Settings = .init(),
        remoteSettings: HTTP3Settings = .init(),
        expectLocalQPACK: Bool = false,
        expectRemoteQPACK: Bool = false
    ) -> HTTP3ConnectionStateMachine {
        assert(idGenerator.type == type)
        var stateMachine = HTTP3ConnectionStateMachine(settings: localSettings, type: type)
        let action1 = stateMachine.initialize()
        switch action1 {
        case .createControlStream:
            stateMachine.outboundControlStreamReady(streamID: idGenerator.outboundUni())
        case .createControlAndDecoderStreams:
            #expect(expectLocalQPACK)
            stateMachine.outboundControlStreamReady(streamID: idGenerator.outboundUni())
            let action2 = stateMachine.outboundDecoderStreamReady(streamID: idGenerator.outboundUni())
            switch action2 {
            case .sendDecoderInstructions:
                Issue.record()
            case .none:
                break  // Expected
            }
        case .none:
            Issue.record()
        }

        // inbound control stream
        let action2a = stateMachine.inboundControlStreamReceived(streamID: idGenerator.inboundUni())
        switch action2a {
        case .addHandlers:
            break
        default:
            Issue.record()
        }

        // receive remotes settings
        let action3 = stateMachine.receivedControlFrame(.settings(remoteSettings))
        switch action3 {
        case .makeEncoderInstructionStream:
            // We shouldn't be asked to make an encoder stream if remote qpack isn't enabled.
            #expect(expectRemoteQPACK)
            let action3 = stateMachine.outboundEncoderStreamReady(streamID: idGenerator.outboundUni())
            switch action3 {
            case .sendEncoderInstruction(let ins):
                #expect(ins == .setDynamicTableCapacity(Int(localSettings.qpackMaximumTableCapacity)))
            case .none:
                Issue.record()
            }
        default:
            // We should be asked to make an encoder stream if remote qpack is enabled.
            #expect(!expectRemoteQPACK)
        }

        return stateMachine
    }
}
