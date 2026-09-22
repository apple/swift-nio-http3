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

import NIOQUICHelpers
@_spi(PackageInternal) import QPACK
import Testing

@_spi(PackageInternal) @testable import HTTP3

struct HTTP3ConnectionStateMachineTests {
    // MARK: Initialization

    @available(anyAppleOS 26, *)
    @Test func initialize() {
        let testSettings = HTTP3Settings()
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)
        let action = stateMachine.initialize()
        #expect(action == .createControlStream)
    }

    @available(anyAppleOS 26, *)
    @Test func initializeAfterFinish() {
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .client)
        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)
        #expect(stateMachine.initialize() == nil)
    }

    // MARK: Inbound streams

    @available(anyAppleOS 26, *)
    @Test func inboundControlStream() {
        let testSettings = HTTP3Settings()
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

        let action2 = stateMachine.inboundControlStreamReceived(streamID: 3)
        guard case .addHandlers = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
    }

    @available(anyAppleOS 26, *)
    @Test func inboundControlStreamAfterShutdown() {
        let testSettings = HTTP3Settings()
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action2 = stateMachine.inboundControlStreamReceived(streamID: 3)
        guard case .emitStreamError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .streamCreationError)
    }

    @available(anyAppleOS 26, *)
    @Test func doubleInboundControlStream() {
        let testSettings = HTTP3Settings()
        var stateMachine = HTTP3ConnectionStateMachine(settings: testSettings, type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

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
        error.expect(code: .invalidStream, h3ErrorCode: .streamCreationError)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundPushStreamOnServer() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action = stateMachine.inboundPushStreamReceived(streamID: idGenerator.inboundUni())
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .streamCreationError)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundPushStreamOnClient() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action = stateMachine.inboundPushStreamReceived(streamID: idGenerator.inboundUni())
        guard case .emitConnectionError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .idError)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundPushStreamAfterShutdown() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action = stateMachine.inboundPushStreamReceived(streamID: idGenerator.inboundUni())
        guard case .emitStreamError(let error) = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .streamCreationError)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundQPACKEncoderStream() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action = stateMachine.inboundQPACKEncoderStreamReceived(streamID: idGenerator.inboundUni())
        guard case .addHandlers = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
    }

    @available(anyAppleOS 26, *)
    @Test func doubleInboundQPACKEncoderStream() {
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
        error.expect(code: .invalidStream, h3ErrorCode: .streamCreationError)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundQPACKEncoderStreamAfterShutdown() {
        let testSettings = HTTP3Settings()
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
            expectedH3ErrorCode: .streamCreationError
        )
    }

    @available(anyAppleOS 26, *)
    @Test func inboundQPACKDecoderStream() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action = stateMachine.inboundQPACKDecoderStreamReceived(streamID: idGenerator.inboundUni())
        guard case .addHandlers = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
    }

    @available(anyAppleOS 26, *)
    @Test func doubleInboundQPACKDecoderStream() {
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
        error.expect(code: .invalidStream, h3ErrorCode: .streamCreationError)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundQPACKDecoderStreamAfterShutdown() {
        let testSettings = HTTP3Settings()
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
            expectedH3ErrorCode: .streamCreationError
        )
    }

    @available(anyAppleOS 26, *)
    @Test func inboundRequestStreamOnServer() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action2 = stateMachine.inboundRequestStreamReceived(streamID: idGenerator.inboundBidi())
        guard case .addHandlers = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
    }

    @available(anyAppleOS 26, *)
    @Test func inboundRequestStreamOnClient() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action2 = stateMachine.inboundRequestStreamReceived(streamID: idGenerator.inboundBidi())
        guard case .emitConnectionError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }

        error.expect(code: .streamCreationError, h3ErrorCode: .streamCreationError)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundRequestStreamAfterShutdown() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action2 = stateMachine.inboundRequestStreamReceived(streamID: idGenerator.inboundBidi())
        guard case .emitStreamError(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: .streamCreationError)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundRequestStreamAfterGoawayWithHigherID() {
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
        expectH3ErrorEqual(error: error, expectedCode: .rejected, expectedH3ErrorCode: .requestRejected)
    }

    @available(anyAppleOS 26, *)
    @Test func inboundUnknownStream() {
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
            expectedH3ErrorCode: .streamCreationError,
            expectedMessage: "Rejecting inbound stream of unknown type 100"
        )
    }

    @available(anyAppleOS 26, *)
    @Test func inboundUnknownStreamAfterShutdown() {
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
            expectedH3ErrorCode: .streamCreationError,
            expectedMessage: "Rejecting inbound stream of unknown type 100"
        )
    }

    // MARK: Settings

    @available(anyAppleOS 26, *)
    @Test func gotSettingsNoQPACK() {
        let remoteSettings = HTTP3Settings(qpackMaximumTableCapacity: 0)
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .client)
        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)
        let action2 = stateMachine.receivedControlFrame(.settings(remoteSettings))
        guard case .onSettings(let settings) = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }
        #expect(!settings.datagramsNegotiated)
    }

    /// The peer may advertise a dynamic table. We never use it, so its settings are simply ignored.
    @available(anyAppleOS 26, *)
    @Test func gotSettingsWithQPACK() {
        let remoteSettings = HTTP3Settings(qpackMaximumTableCapacity: 100, qpackBlockedStreams: 10)
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

        let action2 = stateMachine.receivedControlFrame(.settings(remoteSettings))
        guard case .onSettings = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }
    }

    @available(anyAppleOS 26, *)
    @Test func gotSettingsAfterShutdown() {
        let remoteSettings = HTTP3Settings()
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .client)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)

        let action2 = stateMachine.receivedControlFrame(.settings(remoteSettings))
        #expect(action2 == nil)
    }

    // MARK: GOAWAY

    @available(anyAppleOS 26, *)
    @Test func gotGoawayWithNoStreams() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action = stateMachine.receivedControlFrame(.goaway(4))
        // There are no streams so we immediately close
        guard case .closeConnection = action else {
            Issue.record("Unexpected action \(String(describing: action))")
            return
        }
    }

    @available(anyAppleOS 26, *)
    @Test(arguments: [
        1 as HTTP3GoawayID,  // Server-initiated bidi
        2,  // Client-initiated uni
        3,  // Server-initiated uni
    ])
    // Note: Theres no such thing as an invalid ID on the server. Because the server takes push ids, not stream ids, and those can be any number.
    func gotGoawayWithInvalidIDOnClient(testID: HTTP3GoawayID) {
        let remoteSettings = HTTP3Settings()
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
            expectedH3ErrorCode: .idError
        )
    }

    @available(anyAppleOS 26, *)
    @Test func gotGoawayOnServerDoesNothing() {
        let remoteSettings = HTTP3Settings()
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .server)

        let action1 = stateMachine.initialize()
        #expect(action1 == .createControlStream)

        // We must always get settings before anything else on the control stream
        _ = stateMachine.receivedControlFrame(.settings(remoteSettings))

        let action2 = stateMachine.receivedControlFrame(.goaway(0))
        #expect(action2 == nil)  // Does nothing for now..because we haven't implemented push
    }

    @available(anyAppleOS 26, *)
    @Test func gotGoawayCancelsStream() {
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
        let action3 = stateMachine.streamClosed(streamID: 8, streamType: .request)
        let action4 = stateMachine.streamClosed(streamID: 4, streamType: .request)

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
        let action6 = stateMachine.streamClosed(streamID: 0, streamType: .request)
        guard case .closeConnection = action6 else {
            Issue.record("Unexpected action \(String(describing: action6))")
            return
        }
    }

    /// When the server sends a goaway, we should explicitly cancel streams above that ID
    @available(anyAppleOS 26, *)
    @Test func sendGoawayCancelsStream() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        // Let's say we have some request streams already
        _ = stateMachine.inboundRequestStreamReceived(streamID: 0)
        _ = stateMachine.inboundRequestStreamReceived(streamID: 4)
        _ = stateMachine.inboundRequestStreamReceived(streamID: 8)

        // And then send a goaway with id 4. It should cancel the streams >= that id
        let action2 = stateMachine.sendGoaway(goawayID: 4)
        guard case .sendGoaway(let idToSend, let idsToCancel, let firstRejectedStreamID) = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }
        #expect(idToSend == 4)
        #expect(idsToCancel.sorted() == [4, 8])
        // Servers reject streams at or above the ID they send.
        #expect(firstRejectedStreamID == 4)

        // Those streams got cancelled successfuly
        let action3 = stateMachine.streamClosed(streamID: 8, streamType: .request)
        let action4 = stateMachine.streamClosed(streamID: 4, streamType: .request)

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
        let action6 = stateMachine.streamClosed(streamID: 0, streamType: .request)
        guard case .closeConnection = action6 else {
            Issue.record("Unexpected action \(String(describing: action6))")
            return
        }
    }

    // MARK: Push

    @available(anyAppleOS 26, *)
    @Test func maxPushIDOnServer() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        // TODO: https://github.com/apple/swift-nio-http3/issues/1
        // For now, push related frames are dropped.
        #expect(stateMachine.receivedControlFrame(.maxPushID(1)) == nil)
    }

    @available(anyAppleOS 26, *)
    @Test func maxPushIDOnClient() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        // A client MUST treat the receipt of a MAX_PUSH_ID frame as a connection error of type H3_FRAME_UNEXPECTED.
        let action = stateMachine.receivedControlFrame(.maxPushID(1))
        switch action {
        case .emitConnectionError(let error):
            expectH3ErrorEqual(error: error, expectedCode: .unexpectedFrame, expectedH3ErrorCode: .frameUnexpected)
        default:
            Issue.record("Unexpected action: \(String(describing: action))")
        }
    }

    @available(anyAppleOS 26, *)
    @Test(arguments: [HTTP3ConnectionType.server, .client])
    func cancelPush(type: HTTP3ConnectionType) {
        var idGenerator = IDGenerator(type: type)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: type, idGenerator: &idGenerator)

        // TODO: https://github.com/apple/swift-nio-http3/issues/1
        // For now, push related frames are dropped.
        #expect(stateMachine.receivedControlFrame(.cancelPush(1)) == nil)
    }

    // MARK: Outbound streams

    @available(anyAppleOS 26, *)
    @Test func outboundRequestStreamFromClient() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)

        let action2 = stateMachine.outboundRequestStreamRequested()
        guard case .create = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
    }

    @available(anyAppleOS 26, *)
    @Test func outboundRequestStreamFromServer() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let action2 = stateMachine.outboundRequestStreamRequested()
        guard case .failedToCreateStream(let error) = action2 else {
            Issue.record("Unexpected action \(action2)")
            return
        }
        error.expect(code: .streamCreationError, h3ErrorCode: nil)
    }

    @available(anyAppleOS 26, *)
    @Test func outboundRequestStreamAfterShutdown() {
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

    @available(anyAppleOS 26, *)
    @Test func outboundRequestStreamAfteReceiveGoaway() {
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

    // MARK: Stream tests

    @available(anyAppleOS 26, *)
    @Test func streamError() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .client, idGenerator: &idGenerator)
        let testError = HTTP3Error(
            code: .invalidFramePayload,
            message: "test",
            cause: nil,
            errorCode: .frameError,
            location: .here()
        )
        let action = stateMachine.emitConnectionErrorFromStream(error: testError)
        switch action {
        case .emitConnectionError(let emittedError):
            expectH3ErrorEqual(
                error: emittedError,
                expectedCode: .invalidFramePayload,
                expectedH3ErrorCode: .frameError,
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
    @available(anyAppleOS 26, *)
    @Test func caughtRemoteErrorCancelsStreams() {
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
    @available(anyAppleOS 26, *)
    @Test func caughtRemoteErrorNoStreams() {
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

    @available(anyAppleOS 26, *)
    @Test func criticalStreamClosed() {
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .server)
        let action1 = stateMachine.initialize()
        guard case .createControlStream = action1 else {
            Issue.record("Unexpected action \(String(describing: action1))")
            return
        }

        stateMachine.outboundControlStreamReady(streamID: 3)
        let action2 = stateMachine.streamClosed(streamID: 3, streamType: .unidirectional(.control))
        guard case .emitConnectionError(let connectionError) = action2 else {
            Issue.record("Unexpected action \(String(describing: action2))")
            return
        }
        expectH3ErrorEqual(
            error: connectionError,
            expectedCode: .criticalStreamClosed,
            expectedH3ErrorCode: .closedCriticalStream,
            expectedMessage: "The server-initiated control stream was closed"
        )
    }

    // MARK: Datagrams

    @available(anyAppleOS 26, *)
    @Test func receivedDatagram() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(
            type: .server,
            idGenerator: &idGenerator,
            localSettings: HTTP3Settings(h3Datagram: true),
            remoteSettings: HTTP3Settings(h3Datagram: true)
        )

        #expect(stateMachine.receivedDatagram(streamID: 0).isBuffer)

        let streamID = idGenerator.inboundBidi()
        #expect(stateMachine.inboundRequestStreamReceived(streamID: streamID).isAddHandlers)
        #expect(stateMachine.receivedDatagram(streamID: streamID).isForward)

        _ = stateMachine.streamClosed(streamID: streamID, streamType: .request)
        #expect(stateMachine.receivedDatagram(streamID: streamID).isDiscard)
    }

    @available(anyAppleOS 26, *)
    @Test func receivedDatagramForStreamRejectedByGoaway() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(
            type: .server,
            idGenerator: &idGenerator,
            localSettings: HTTP3Settings(h3Datagram: true),
            remoteSettings: HTTP3Settings(h3Datagram: true)
        )

        // Streams at or above ID 4 are rejected from here on.
        #expect(stateMachine.sendGoaway(goawayID: 4)?.isSendGoaway == true)

        // Stream 0 is below the GOAWAY ID so it can still open.
        #expect(stateMachine.receivedDatagram(streamID: 0).isBuffer)

        // Stream 4 will never open, so there's no point buffering its datagrams.
        #expect(stateMachine.receivedDatagram(streamID: 4).isDiscard)

        // A rejected stream is tracked as open until its stream channel closes, so openness alone
        // isn't enough to tell that its datagrams can't be delivered.
        #expect(stateMachine.inboundRequestStreamReceived(streamID: 4).isEmitStreamError)
        #expect(stateMachine.receivedDatagram(streamID: 4).isDiscard)
    }

    @available(anyAppleOS 26, *)
    @Test func clientGoawayDoesNotDiscardDatagrams() {
        var idGenerator = IDGenerator(type: .client)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(
            type: .client,
            idGenerator: &idGenerator,
            localSettings: HTTP3Settings(h3Datagram: true),
            remoteSettings: HTTP3Settings(h3Datagram: true)
        )

        // A client's GOAWAY carries a push ID, so it says nothing about which request streams the
        // server may send datagrams for.
        #expect(stateMachine.sendGoaway(goawayID: 0)?.isSendGoaway == true)

        let streamID = idGenerator.outboundBidi()
        stateMachine.outboundRequestStreamReady(streamID: streamID)
        #expect(stateMachine.receivedDatagram(streamID: streamID).isForward)
    }

    @available(anyAppleOS 26, *)
    @Test func receivedDatagramWithoutLocalSupport() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(type: .server, idGenerator: &idGenerator)

        let streamID = idGenerator.inboundBidi()
        #expect(stateMachine.inboundRequestStreamReceived(streamID: streamID).isAddHandlers)
        stateMachine.expectReceivingDatagramIsConnectionError(
            streamID: streamID,
            code: .datagramsNotNegotiated
        )
        stateMachine.expectReceivingDatagramIsConnectionError(streamID: 0, code: .datagramsNotNegotiated)
    }

    @available(anyAppleOS 26, *)
    @Test func receivedDatagramBeforeStartedWithoutLocalSupport() {
        let stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .server)
        stateMachine.expectReceivingDatagramIsConnectionError(streamID: 0, code: .datagramsNotNegotiated)
    }

    @available(anyAppleOS 26, *)
    @Test func receivedDatagramWithoutRemoteSupport() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(
            type: .server,
            idGenerator: &idGenerator,
            localSettings: HTTP3Settings(h3Datagram: true)
        )

        // The remote didn't advertise support so it must not send datagrams.
        let streamID = idGenerator.inboundBidi()
        #expect(stateMachine.inboundRequestStreamReceived(streamID: streamID).isAddHandlers)
        stateMachine.expectReceivingDatagramIsConnectionError(streamID: streamID, code: .datagramsNotNegotiated)
    }

    @available(anyAppleOS 26, *)
    @Test(arguments: [true, false], [true, false])
    func settingsReportWhetherDatagramsAreNegotiated(localSupport: Bool, remoteSupport: Bool) {
        var stateMachine = HTTP3ConnectionStateMachine(
            settings: HTTP3Settings(h3Datagram: localSupport),
            type: .client
        )
        _ = stateMachine.initialize()

        let action = stateMachine.receivedControlFrame(.settings(HTTP3Settings(h3Datagram: remoteSupport)))
        guard case .onSettings(let settings) = action else {
            Issue.record("Unexpected action \(String(describing: action))")
            return
        }
        #expect(settings.datagramsNegotiated == (localSupport && remoteSupport))
    }

    @available(anyAppleOS 26, *)
    @Test func emitConnectionErrorBeforeStarted() {
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .server)
        let testError = HTTP3Error(
            code: .datagramsNotNegotiated,
            message: "test",
            cause: nil,
            errorCode: .generalProtocolError,
            location: .here()
        )

        let action = stateMachine.emitConnectionErrorFromStream(error: testError, allowNotStarted: true)
        guard case .emitConnectionError = action else {
            Issue.record("Unexpected action \(action)")
            return
        }
    }

    @available(anyAppleOS 26, *)
    @Test func receiveDatagramBeforeSettings() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine(settings: .init(), type: .server)
        stateMachine.expectSendingDatagramIsDropped(streamID: 0, code: .datagramsNotNegotiated)

        _ = stateMachine.initialize()
        let streamID = idGenerator.inboundBidi()
        #expect(stateMachine.inboundRequestStreamReceived(streamID: streamID).isAddHandlers)

        // The stream is open but no SETTINGS frame has been received to advertise support.
        stateMachine.expectSendingDatagramIsDropped(streamID: streamID, code: .datagramsNotNegotiated)
    }

    @available(anyAppleOS 26, *)
    @Test func sendDatagram() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(
            type: .server,
            idGenerator: &idGenerator,
            localSettings: HTTP3Settings(h3Datagram: true),
            remoteSettings: HTTP3Settings(h3Datagram: true)
        )

        let streamID = idGenerator.inboundBidi()
        #expect(stateMachine.inboundRequestStreamReceived(streamID: streamID).isAddHandlers)
        #expect(stateMachine.sendDatagram(streamID: streamID).isSend)

        _ = stateMachine.streamClosed(streamID: streamID, streamType: .request)
        stateMachine.expectSendingDatagramIsDropped(streamID: streamID, code: .invalidStream)

        #expect(stateMachine.shutdownConnectionImmediately() == .shutdown)
        stateMachine.expectSendingDatagramIsDropped(streamID: streamID, code: .connectionClosed)
    }

    @available(anyAppleOS 26, *)
    @Test func sendDatagramWithoutRemoteSupport() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(
            type: .server,
            idGenerator: &idGenerator,
            localSettings: HTTP3Settings(h3Datagram: true)
        )

        let streamID = idGenerator.inboundBidi()
        #expect(stateMachine.inboundRequestStreamReceived(streamID: streamID).isAddHandlers)
        stateMachine.expectSendingDatagramIsDropped(streamID: streamID, code: .datagramsNotNegotiated)
    }

    @available(anyAppleOS 26, *)
    @Test func sendDatagramWithoutLocalSupport() {
        var idGenerator = IDGenerator(type: .server)
        var stateMachine = HTTP3ConnectionStateMachine.makeInitialized(
            type: .server,
            idGenerator: &idGenerator,
            remoteSettings: HTTP3Settings(h3Datagram: true)
        )

        let streamID = idGenerator.inboundBidi()
        #expect(stateMachine.inboundRequestStreamReceived(streamID: streamID).isAddHandlers)
        stateMachine.expectSendingDatagramIsDropped(streamID: streamID, code: .datagramsNotNegotiated)
    }

    // 1 = server-init bidi, 2 = client-init uni, 3 = server-init uni
    @available(anyAppleOS 26, *)
    @Test(arguments: [1, 2, 3])
    func sendDatagramOnInvalidStream(streamID: QUICStreamID) {
        var idGenerator = IDGenerator(type: .server)
        let stateMachine = HTTP3ConnectionStateMachine.makeInitialized(
            type: .server,
            idGenerator: &idGenerator,
            localSettings: HTTP3Settings(h3Datagram: true),
            remoteSettings: HTTP3Settings(h3Datagram: true)
        )
        stateMachine.expectSendingDatagramIsDropped(streamID: streamID, code: .invalidStream)
    }
}

// MARK: Test utils

@available(anyAppleOS 26, *)
extension HTTP3ConnectionStateMachine.InboundRequestStreamReceivedAction {
    fileprivate var isAddHandlers: Bool {
        switch self {
        case .addHandlers: return true
        case .emitStreamError, .emitConnectionError: return false
        }
    }

    fileprivate var isEmitStreamError: Bool {
        switch self {
        case .emitStreamError: return true
        case .addHandlers, .emitConnectionError: return false
        }
    }
}

@available(anyAppleOS 26, *)
extension HTTP3ConnectionStateMachine.ReceivedDatagramAction {
    fileprivate var isBuffer: Bool {
        switch self {
        case .buffer: return true
        case .forward, .discard, .connectionError: return false
        }
    }

    fileprivate var isForward: Bool {
        switch self {
        case .forward: return true
        case .buffer, .discard, .connectionError: return false
        }
    }

    fileprivate var isDiscard: Bool {
        switch self {
        case .discard: return true
        case .buffer, .forward, .connectionError: return false
        }
    }
}

@available(anyAppleOS 26, *)
extension HTTP3ConnectionStateMachine.SendDatagramAction {
    fileprivate var isSend: Bool {
        switch self {
        case .send: return true
        case .drop: return false
        }
    }
}

@available(anyAppleOS 26, *)
extension HTTP3ConnectionStateMachine.CloseAction {
    fileprivate var isSendGoaway: Bool {
        switch self {
        case .sendGoaway: return true
        case .throwError, .closeImmediately: return false
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

@available(anyAppleOS 26, *)
extension HTTP3ConnectionStateMachine {
    func expectSendingDatagramIsDropped(
        streamID: QUICStreamID,
        code: HTTP3Error.Code,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch self.sendDatagram(streamID: streamID) {
        case .send:
            Issue.record("Datagram for stream \(streamID) was not rejected", sourceLocation: sourceLocation)
        case .drop(let error):
            error.expect(code: code, h3ErrorCode: nil, sourceLocation: sourceLocation)
        }
    }

    func expectReceivingDatagramIsConnectionError(
        streamID: QUICStreamID,
        code: HTTP3Error.Code,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch self.receivedDatagram(streamID: streamID) {
        case .buffer, .forward, .discard:
            Issue.record(
                "Datagram for stream \(streamID) didn't close the connection",
                sourceLocation: sourceLocation
            )
        case .connectionError(let error):
            error.expect(code: code, h3ErrorCode: .generalProtocolError, sourceLocation: sourceLocation)
        }
    }

    /// Returns a state machine which has already exchanged settings with the 'remote' and created the required streams.
    ///
    /// - Parameters:
    ///   - type: The type of connection (client or server)
    ///   - idGenerator: For generating IDs of the streams we'll be making.
    ///   - localSettings: The settings we use for the connection.
    ///   - remoteSettings: The settings the remote 'sent' us.
    /// - Returns: A state machine which has been initialized, created control streams both ways, and exchanged settings.
    static func makeInitialized(
        type: HTTP3ConnectionType,
        idGenerator: inout IDGenerator,
        localSettings: HTTP3Settings = .init(),
        remoteSettings: HTTP3Settings = .init()
    ) -> HTTP3ConnectionStateMachine {
        assert(idGenerator.type == type)
        var stateMachine = HTTP3ConnectionStateMachine(settings: localSettings, type: type)
        let action1 = stateMachine.initialize()
        switch action1 {
        case .createControlStream:
            stateMachine.outboundControlStreamReady(streamID: idGenerator.outboundUni())
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
        case .onSettings:
            break

        default:
            Issue.record("Unexpected action \(String(describing: action3))")
        }

        return stateMachine
    }
}
