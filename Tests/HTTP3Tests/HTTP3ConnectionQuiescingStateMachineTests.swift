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
import Testing

struct HTTP3ConnectionQuiescingStateMachineTests {
    // MARK: Receiving GOAWAY

    @Test
    func testReceiveGoawayOnServer() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .server)
        let action1 = stateMachine.receivedGoaway(newGoawayID: 7)
        #expect(action1 == nil)

        let action2 = stateMachine.receivedGoaway(newGoawayID: 6)
        #expect(action2 == nil)
    }

    @Test
    func testReceiveGoawayOnClient() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)
        let action1 = stateMachine.receivedGoaway(newGoawayID: 24)
        #expect(action1?.cancelStreamsGreaterOrEqualTo == 24)

        let action2 = stateMachine.receivedGoaway(newGoawayID: 20)
        #expect(action2?.cancelStreamsGreaterOrEqualTo == 20)
    }

    @Test(arguments: [1, 2, 3, 5, 6, 7] as [HTTP3GoawayID])
    func testReceiveGoawayOnClientNotAValidID(testID: HTTP3GoawayID) throws {
        // ID should be of a request stream
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)
        let action = stateMachine.receivedGoaway(newGoawayID: testID)
        expectH3ErrorEqual(
            error: action?.connectionError,
            expectedCode: .invalidGoawayStreamID,
            expectedH3ErrorCode: .idError
        )
    }

    @Test(arguments: [HTTP3ConnectionType.server, .client])
    func increasedRemoteID(type: HTTP3ConnectionType) throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: type)
        _ = stateMachine.receivedGoaway(newGoawayID: 24)
        let action = stateMachine.receivedGoaway(newGoawayID: 28)
        expectH3ErrorEqual(
            error: action?.connectionError,
            expectedCode: .invalidGoawayStreamID,
            expectedH3ErrorCode: .idError
        )
    }

    @Test(arguments: [HTTP3ConnectionType.server, .client])
    func increasedRemoteIDAfterSendGoaway(type: HTTP3ConnectionType) throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: type)
        _ = stateMachine.sendGoaway(goawayID: 0)
        _ = stateMachine.receivedGoaway(newGoawayID: 24)
        let action = stateMachine.receivedGoaway(newGoawayID: 28)
        expectH3ErrorEqual(
            error: action?.connectionError,
            expectedCode: .invalidGoawayStreamID,
            expectedH3ErrorCode: .idError
        )
    }

    @Test
    func testReceiveGoawayOnClientAfterSending() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)

        let action1 = stateMachine.sendGoaway(goawayID: 3)
        #expect(action1.sendGoawayID == 3)

        let action2 = stateMachine.receivedGoaway(newGoawayID: 24)
        #expect(action2?.cancelStreamsGreaterOrEqualTo == 24)

        let action3 = stateMachine.receivedGoaway(newGoawayID: 20)
        #expect(action3?.cancelStreamsGreaterOrEqualTo == 20)
    }

    @Test
    func testReceiveGoawayOnServerAfterSending() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .server)

        let action1 = stateMachine.sendGoaway(goawayID: 4)
        #expect(action1.sendGoawayID == 4)

        let action2 = stateMachine.receivedGoaway(newGoawayID: 2)
        #expect(action2 == nil)

        let action3 = stateMachine.receivedGoaway(newGoawayID: 1)
        #expect(action3 == nil)
    }

    // MARK: Send GOAWAY

    @Test
    func sendGoawayFromClient() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)

        let action1 = stateMachine.sendGoaway(goawayID: 10)
        #expect(action1.sendGoawayID == 10)

        let action2 = stateMachine.sendGoaway(goawayID: 5)
        #expect(action2.sendGoawayID == 5)

        let action3 = stateMachine.sendGoaway(goawayID: 7)
        expectH3ErrorEqual(
            error: action3.throwError,
            expectedCode: .invalidGoawayStreamID,
            expectedH3ErrorCode: .idError
        )
    }

    @Test
    func sendGoawayFromServer() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .server)

        // Send one..that's fine
        let action1 = stateMachine.sendGoaway(goawayID: 100)
        #expect(action1.sendGoawayID == 100)

        // Send another one with a lower id..also fine
        let action2 = stateMachine.sendGoaway(goawayID: 40)
        #expect(action2.sendGoawayID == 40)

        // Send one with an invalid ID (not a multiple of 4, so it's not a client-initiated bidi stream)
        let action3 = stateMachine.sendGoaway(goawayID: 30)
        expectH3ErrorEqual(
            error: action3.throwError,
            expectedCode: .invalidGoawayStreamID,
            expectedH3ErrorCode: nil
        )

        // This is a multiple of 4 but it's higher than a previously sent goaway
        let action4 = stateMachine.sendGoaway(goawayID: 80)
        expectH3ErrorEqual(
            error: action4.throwError,
            expectedCode: .invalidGoawayStreamID,
            expectedH3ErrorCode: .idError
        )
    }

    @Test(arguments: [HTTP3ConnectionType.server, .client])
    func sendGoawayAfterReceiving(type: HTTP3ConnectionType) throws {
        // This test works the same for both clients and servers.
        // Servers must send multiples of 4, clients can send any number.
        // This test uses multiples of 4 only, to make the test work with both types, to avoid duplicating the test.
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: type)

        _ = stateMachine.receivedGoaway(newGoawayID: 40)

        let action1 = stateMachine.sendGoaway(goawayID: 100)
        #expect(action1.sendGoawayID == 100)

        let action2 = stateMachine.sendGoaway(goawayID: 40)
        #expect(action2.sendGoawayID == 40)

        let action3 = stateMachine.sendGoaway(goawayID: 80)
        expectH3ErrorEqual(
            error: action3.throwError,
            expectedCode: .invalidGoawayStreamID,
            expectedH3ErrorCode: .idError
        )
    }

    // MARK: Create outbound streams

    @Test
    func createOutboundRequestStream() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)

        // I can make many streams because i didn't get a goaway
        for _ in 0...10 {
            let action = stateMachine.createOutboundRequestStream()
            #expect(action.create)
        }

        _ = stateMachine.receivedGoaway(newGoawayID: 400)

        // I can no longer make streams

        let action2 = stateMachine.createOutboundRequestStream()
        #expect(!action2.create)
    }

    @Test
    func createOutboundRequestStreamAfterSendingGoaway() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)

        let action1 = stateMachine.sendGoaway(goawayID: 1)
        #expect(action1.sendGoawayID == 1)

        // I can make many streams because i didn't get a goaway, even though i sent one
        for _ in 0...10 {
            let action = stateMachine.createOutboundRequestStream()
            #expect(action.create)
        }

        _ = stateMachine.receivedGoaway(newGoawayID: 400)

        // I can no longer make streams

        let action2 = stateMachine.createOutboundRequestStream()
        #expect(!action2.create)
    }

    // MARK: Incoming requests

    @Test
    func receiveInboundRequestStream() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .server)

        // Incoming requests are fine because we didn't send a goaway
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 0) == true)
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 4) == true)

        // We send a goaway, we won't accept streams ≥ 100
        _ = stateMachine.sendGoaway(goawayID: 100)

        // Streams below 100 still fine
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 8) == true)
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 12) == true)
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 96) == true)

        // Above 100 not fine
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 100) == false)
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 104) == false)
    }

    @Test
    func receiveInboundRequestStreamAfterReceiveGoaway() throws {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .server)

        _ = stateMachine.receivedGoaway(newGoawayID: 400)

        // Incoming requests are fine because we didn't send a goaway, even if we received one
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 0) == true)
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 4) == true)

        // We send a goaway, we won't accept streams ≥ 100
        _ = stateMachine.sendGoaway(goawayID: 100)

        // Streams below 100 still fine
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 8) == true)
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 12) == true)
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 96) == true)

        // Above 100 not fine
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 100) == false)
        #expect(stateMachine.inboundRequestStreamAllowed(incomingStreamID: 104) == false)
    }

    // MARK: Check should close connection

    @Test(arguments: [HTTP3ConnectionType.server, .client])
    func testRequestStreamClosedBeforeQuiescing(type: HTTP3ConnectionType) {
        let stateMachine = HTTP3ConnectionQuiescingStateMachine(type: type)
        let action = stateMachine.shouldCloseConnection()
        // Neither side has quiesced, nothing to do.
        #expect(action == .doNotClose)
    }

    @Test
    func testRequestStreamClosedWhilstLocallyQuiescingOnClient() {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)
        _ = stateMachine.sendGoaway(goawayID: 40)
        let action = stateMachine.shouldCloseConnection()
        // We are a client, we won't shutdown even if we have no open streams
        // We told the server to goaway, but we can still keep making requests
        #expect(action == .doNotClose)
    }

    @Test
    func testRequestStreamClosedWhilstLocallyQuiescingOnServer() {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .server)
        _ = stateMachine.sendGoaway(goawayID: 40)
        let action = stateMachine.shouldCloseConnection()
        // We are a server, we told the client to go away.
        // We can shut down if there are no open streams AND we can be sure there aren't any in-flight
        #expect(action == .closeIfExhaustedStreamsAndNonOpen(maxID: 40))
    }

    @Test
    func testRequestStreamClosedWhilstRemotelyQuiescingOnClient() {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)
        _ = stateMachine.receivedGoaway(newGoawayID: 40)
        let action = stateMachine.shouldCloseConnection()
        // The server told us to go away. We will, but only if we have no streams open.
        #expect(action == .closeIfNoOpenStreams)
    }

    @Test
    func testRequestStreamClosedWhilstRemotelyQuiescingOnServer() {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .server)
        _ = stateMachine.receivedGoaway(newGoawayID: 40)
        let action = stateMachine.shouldCloseConnection()
        // The client told us to goaway. That means we won't send pushes. But we'll still accept requests.
        #expect(action == .doNotClose)
    }

    @Test
    func testRequestStreamClosedWhilstBothQuiescingOnClient() {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .client)
        _ = stateMachine.receivedGoaway(newGoawayID: 40)
        _ = stateMachine.sendGoaway(goawayID: 40)
        let action = stateMachine.shouldCloseConnection()
        // Both sides are quiescing. We are a client. We will close the connection if we have no streams open.
        #expect(action == .closeIfNoOpenStreams)
    }

    @Test
    func testRequestStreamClosedWhilstBothQuiescingOnServer() {
        var stateMachine = HTTP3ConnectionQuiescingStateMachine(type: .server)
        _ = stateMachine.receivedGoaway(newGoawayID: 40)
        _ = stateMachine.sendGoaway(goawayID: 40)
        let action = stateMachine.shouldCloseConnection()
        // Both sides are quiescing. We are a server.
        // We can shut down if there are no open streams AND we can be sure there aren't any in-flight
        #expect(action == .closeIfExhaustedStreamsAndNonOpen(maxID: 40))
    }
}

// MARK: Test helpers

extension HTTP3ConnectionQuiescingStateMachine.ReceivedGoawayAction {
    fileprivate var cancelStreamsGreaterOrEqualTo: QUICStreamID? {
        switch self {
        case .cancelStreamsOrCloseIfNone(let streamID): return streamID
        default: return nil
        }
    }

    fileprivate var connectionError: HTTP3Error? {
        switch self {
        case .emitConnectionError(let error): return error
        default: return nil
        }
    }
}

extension HTTP3ConnectionQuiescingStateMachine.SendGoawayAction {
    fileprivate var sendGoawayID: HTTP3GoawayID? {
        switch self {
        case .sendGoaway(let id): return id
        default: return nil
        }
    }

    fileprivate var throwError: HTTP3Error? {
        switch self {
        case .throwError(let error): return error
        default: return nil
        }
    }
}

extension HTTP3ConnectionQuiescingStateMachine.CreateOutboundRequestStreamAction {
    fileprivate var create: Bool {
        switch self {
        case .create: return true
        case .failToCreate: return false
        }
    }
}
