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

package import DequeModule
package import HTTPTypes
package import Logging
package import NIOQUICHelpers
package import QPACK

package enum HTTP3ConnectionType {
    case client
    case server
}

package struct HTTP3ConnectionStateMachine: ~Copyable {
    struct InboundStreamCreationState: ~Copyable {
        private enum State: ~Copyable {
            case notCreated
            case created
        }

        private let state: State

        init() {
            self.init(state: .notCreated)
        }

        private init(state: consuming State) {
            self.state = state
        }

        enum StreamReceivedAction {
            case addHandlers
            case emitConnectionError(HTTP3Error)
        }

        mutating func streamReceived() -> StreamReceivedAction {
            switch consume self.state {
            case .notCreated:
                self = .init(state: .created)
                return .addHandlers
            case .created:
                // Receipt of a second instance of either stream type MUST be treated as a connection error of type H3_STREAM_CREATION_ERROR.
                self = .init(state: .created)
                return .emitConnectionError(
                    HTTP3Error(
                        code: .invalidStream,
                        message: "Received a duplicate incoming stream",
                        cause: nil,
                        errorCode: .H3_STREAM_CREATION_ERROR,
                        location: .here()
                    )
                )
            }
        }
    }

    enum State: ~Copyable {
        case notStarted(NotStarted)
        case initialized(Initialized)
        /// We have shutdown the connection. The QUIC layer below us should also be shutdown, so we should not see any new streams, or any data on existing streams.
        /// If we do, we'll just drop it.
        case finished

        struct NotStarted: ~Copyable {
            var qpackState: QPACKStateMachine
            /// Our own settings that we will send to the remote.
            let localSettings: HTTP3Settings
            /// The type of the connection (client or server).
            let type: HTTP3ConnectionType
        }

        struct Initialized: ~Copyable {
            var inboundControlStream: InboundStreamCreationState
            var inboundQPACKDecoderStream: InboundStreamCreationState
            var inboundQPACKEncoderStream: InboundStreamCreationState
            var qpackState: QPACKStateMachine
            /// The type of the connection (client or server).
            let type: HTTP3ConnectionType
            let localDynamicTableSize: Int
            var streamIDTracker = StreamIDTracker()
            var quiescingState: HTTP3ConnectionQuiescingStateMachine

            init(notStarted: consuming NotStarted) {
                self.inboundControlStream = .init()
                self.inboundQPACKDecoderStream = .init()
                self.inboundQPACKEncoderStream = .init()
                self.qpackState = notStarted.qpackState
                self.type = notStarted.type
                self.localDynamicTableSize = Int(clamping: notStarted.localSettings.qpackMaximumTableCapacity)
                self.quiescingState = .init(type: notStarted.type)
            }
        }
    }

    private let state: State

    package init(settings: HTTP3Settings, type: HTTP3ConnectionType) {
        let qpackState = QPACKStateMachine(
            decoderMaxTableSize: Int(clamping: settings.qpackMaximumTableCapacity),
            decoderMaxBlockedStreams: Int(clamping: settings.qpackBlockedStreams)
        )
        self.init(state: .notStarted(.init(qpackState: qpackState, localSettings: settings, type: type)))
    }

    private init(state: consuming State) {
        self.state = state
    }

    // MARK: Initialization

    package enum InitializeAction: Hashable, Sendable {
        case createControlAndDecoderStreams
        case createControlStream
    }

    package mutating func initialize() -> InitializeAction? {
        switch consume self.state {
        case .notStarted(let initializedState):
            let localSettings = initializedState.localSettings
            self = .init(
                state: .initialized(
                    .init(
                        notStarted: initializedState
                    )
                )
            )
            // RFC 9204 § 4.2: An endpoint MAY avoid creating a decoder stream if its decoder sets the maximum capacity of the dynamic table to zero.
            if localSettings.qpackMaximumTableCapacity > 0 {
                return .createControlAndDecoderStreams
            } else {
                return .createControlStream
            }
        case .initialized:
            fatalError("Cannot initialize HTTP3 connection twice")
        case .finished:
            self = .init(state: .finished)
            return .none
        }
    }

    // MARK: Inbound streams

    package enum InboundRequestStreamReceivedAction {
        case addHandlers
        case emitStreamError(HTTP3Error)
        case emitConnectionError(HTTP3Error)
    }

    package mutating func inboundRequestStreamReceived(streamID: QUICStreamID) -> InboundRequestStreamReceivedAction {
        precondition(streamID.isBidirectional, "Stream ID \(streamID) was expected to be bidirectional")
        switch consume self.state {
        case .notStarted:
            fatalError("Inbound request stream received before state machine started")
        case .finished:
            // reject this stream
            self = .init(state: .finished)
            return .emitStreamError(.rejectIncomingStreamDueToShuttingDown(location: .here()))
        case .initialized(var initializedState):
            switch initializedState.type {
            case .server:
                precondition(streamID.isClientInitiated, "Stream ID \(streamID) was expected to be client initiated")
                initializedState.streamIDTracker.streamOpened(id: streamID)
                if initializedState.quiescingState.inboundRequestStreamAllowed(incomingStreamID: streamID) {
                    self = .init(state: .initialized(initializedState))
                    return .addHandlers
                } else {
                    // This stream ID is too high, we won't accept it.
                    // When the server cancels a request without performing any application processing, the request is considered "rejected".
                    // The server SHOULD abort its response stream with the error code H3_REQUEST_REJECTED.
                    self = .init(state: .initialized(initializedState))
                    return .emitStreamError(
                        HTTP3Error(
                            code: .rejected,
                            message: "Stream rejected due to server shutting down",
                            cause: nil,
                            errorCode: .H3_REQUEST_REJECTED,
                            location: .here()
                        )
                    )
                }
            case .client:
                precondition(streamID.isServerInitiated, "Stream ID \(streamID) was expected to be server initiated")
                self = .init(state: .finished)
                // 6.1: HTTP/3 does not use server-initiated bidirectional streams, though an extension could define a use for these streams.
                // Clients MUST treat receipt of a server-initiated bidirectional stream as a connection error of type H3_STREAM_CREATION_ERROR unless such an extension has been negotiated.
                return .emitConnectionError(
                    HTTP3Error(
                        code: .streamCreationError,
                        message: "Incoming request stream on client",
                        cause: nil,
                        errorCode: .H3_STREAM_CREATION_ERROR,
                        location: .here()
                    )
                )
            }
        }
    }

    package enum InboundControlStreamReceivedAction {
        case addHandlers
        case emitConnectionError(HTTP3Error)
        case emitStreamError(HTTP3Error)
    }

    package mutating func inboundControlStreamReceived(streamID: QUICStreamID) -> InboundControlStreamReceivedAction {
        precondition(streamID.isUnidirectional, "Stream ID \(streamID) was expected to be unidirectional")
        switch consume self.state {
        case .notStarted:
            fatalError("Inbound control stream received before state machine started")
        case .finished:
            // reject this stream
            self = .init(state: .finished)
            return .emitStreamError(.rejectIncomingStreamDueToShuttingDown(location: .here()))
        case .initialized(var initializedState):
            initializedState.streamIDTracker.streamOpened(id: streamID)
            let action = initializedState.inboundControlStream.streamReceived()
            switch action {
            case .addHandlers:
                self = .init(state: .initialized(initializedState))
                return .addHandlers
            case .emitConnectionError(let error):
                self = .init(state: .finished)
                return .emitConnectionError(error)
            }
        }
    }

    package enum InboundPushStreamReceivedAction {
        case emitConnectionError(HTTP3Error)
        case emitStreamError(HTTP3Error)
    }

    package mutating func inboundPushStreamReceived(streamID: QUICStreamID) -> InboundPushStreamReceivedAction {
        precondition(streamID.isUnidirectional, "Stream ID \(streamID) was expected to be unidirectional")
        switch consume self.state {
        case .notStarted:
            fatalError("Inbound push stream received before state machine started")
        case .finished:
            // reject this stream
            self = .init(state: .finished)
            return .emitStreamError(.rejectIncomingStreamDueToShuttingDown(location: .here()))
        case .initialized(var initializedState):
            initializedState.streamIDTracker.streamOpened(id: streamID)
            switch initializedState.type {
            case .server:
                // RFC 9114 § 6.2.2: Only servers can push; if a server receives a client-initiated push stream,
                // this MUST be treated as a connection error of type H3_STREAM_CREATION_ERROR.
                self = .init(state: .finished)
                return .emitConnectionError(
                    HTTP3Error(
                        code: .streamCreationError,
                        message: "Cannot accept push stream on server",
                        cause: nil,
                        errorCode: .H3_STREAM_CREATION_ERROR,
                        location: .here()
                    )
                )
            case .client:
                // A client MUST treat receipt of a push stream as a connection error of type H3_ID_ERROR when no
                // MAX_PUSH_ID frame has been sent or when the stream references a push ID that is greater than the maximum push ID.
                // TODO: https://github.com/apple/swift-nio-http3/issues/1
                // Until then, all incoming push streams are an error.
                self = .init(state: .finished)
                return .emitConnectionError(
                    HTTP3Error(
                        code: .streamCreationError,
                        message: "Rejecting inbound push stream with invalid ID",
                        cause: nil,
                        errorCode: .H3_ID_ERROR,
                        location: .here()
                    )
                )
            }
        }
    }

    package enum InboundQPACKStreamReceivedAction {
        case addHandlers
        case emitConnectionError(HTTP3Error)
        case emitStreamError(HTTP3Error)
    }

    package mutating func inboundQPACKDecoderStreamReceived(streamID: QUICStreamID) -> InboundQPACKStreamReceivedAction
    {
        precondition(streamID.isUnidirectional, "Stream ID \(streamID) was expected to be unidirectional")
        switch consume self.state {
        case .notStarted:
            fatalError("Inbound decoder stream received before state machine started")
        case .finished:
            // reject this stream
            self = .init(state: .finished)
            return .emitStreamError(.rejectIncomingStreamDueToShuttingDown(location: .here()))
        case .initialized(var initializedState):
            initializedState.streamIDTracker.streamOpened(id: streamID)
            let action = initializedState.inboundQPACKDecoderStream.streamReceived()
            switch action {
            case .addHandlers:
                self = .init(state: .initialized(initializedState))
                return .addHandlers
            case .emitConnectionError(let error):
                self = .init(state: .finished)
                return .emitConnectionError(error)
            }
        }
    }

    package mutating func inboundQPACKEncoderStreamReceived(streamID: QUICStreamID) -> InboundQPACKStreamReceivedAction
    {
        precondition(streamID.isUnidirectional, "Stream ID \(streamID) was expected to be unidirectional")
        switch consume self.state {
        case .notStarted:
            fatalError("Inbound encoder stream received before state machine started")
        case .finished:
            // reject this stream
            self = .init(state: .finished)
            return .emitStreamError(.rejectIncomingStreamDueToShuttingDown(location: .here()))
        case .initialized(var initializedState):
            initializedState.streamIDTracker.streamOpened(id: streamID)
            let action = initializedState.inboundQPACKEncoderStream.streamReceived()
            switch action {
            case .addHandlers:
                self = .init(state: .initialized(initializedState))
                return .addHandlers
            case .emitConnectionError(let error):
                self = .init(state: .finished)
                return .emitConnectionError(error)
            }
        }
    }

    package enum InboundUnknownStreamAction {
        case emitStreamError(HTTP3Error)
    }

    package mutating func inboundUnknownStreamReceived(
        streamID: QUICStreamID,
        streamType: HTTP3StreamType.Unidirectional
    ) -> InboundUnknownStreamAction {
        precondition(streamID.isUnidirectional, "Stream ID \(streamID) was expected to be unidirectional")
        switch consume self.state {
        case .notStarted:
            fatalError("Inbound stream received before state machine started")
        case .finished:
            // reject this stream
            self = .init(state: .finished)
            return .emitStreamError(.rejectIncomingStreamDueToShuttingDown(location: .here()))
        case .initialized(var initializedState):
            initializedState.streamIDTracker.streamOpened(id: streamID)
            self = .init(state: .initialized(initializedState))
            // We don't understand the stream type
            // RFC 9114: Recipients of unknown stream types MUST either abort reading of the stream or discard incoming data without further processing
            // If reading is aborted, the recipient SHOULD use the H3_STREAM_CREATION_ERROR error code
            return .emitStreamError(
                HTTP3Error(
                    code: .streamCreationError,
                    message: "Rejecting inbound stream of unknown type \(streamType.rawValue)",
                    cause: nil,
                    errorCode: .H3_STREAM_CREATION_ERROR,
                    location: .here()
                )
            )
        }
    }

    // MARK: Outbound Streams

    package enum OutboundEncoderStreamReadyAction: Hashable {
        case sendEncoderInstruction(QPACKEncoderInstruction)
    }

    package mutating func outboundEncoderStreamReady(streamID: QUICStreamID) -> OutboundEncoderStreamReadyAction? {
        precondition(streamID.isUnidirectional)
        switch consume self.state {
        case .initialized(var initializedState):
            initializedState.streamIDTracker.streamOpened(id: streamID)
            let instruction = initializedState.qpackState.outboundEncoderStreamReady()
            self = .init(state: .initialized(initializedState))
            switch instruction {
            case .sendEncoderInstruction(let instruction?):
                return .sendEncoderInstruction(instruction)
            case .sendEncoderInstruction(.none):
                return .none
            }
        case .notStarted:
            fatalError("Outbound encoder stream created before state machine started")
        case .finished:
            self = .init(state: .finished)
            return .none
        }
    }

    package enum OutboundDecoderStreamReadyAction: Hashable, Sendable {
        case sendDecoderInstructions(Deque<QPACKDecoderInstruction>)
    }

    package mutating func outboundDecoderStreamReady(streamID: QUICStreamID) -> OutboundDecoderStreamReadyAction? {
        precondition(streamID.isUnidirectional)
        switch consume self.state {
        case .initialized(var initializedState):
            initializedState.streamIDTracker.streamOpened(id: streamID)
            let result = initializedState.qpackState.outboundDecoderStreamReady()
            self = .init(state: .initialized(initializedState))
            switch result {
            case .sendDecoderInstructions(let instructions):
                return .sendDecoderInstructions(instructions)
            case .none:
                return .none
            }
        case .notStarted:
            fatalError("Outbound decoder stream created before state machine started")
        case .finished:
            self = .init(state: .finished)
            return nil
        }
    }

    package enum OutboundRequestStreamRequestedAction {
        case create
        case failedToCreateStream(HTTP3Error)
    }

    /// Call this before making a request stream. It will tell you whether or not you may create it.
    package mutating func outboundRequestStreamRequested() -> OutboundRequestStreamRequestedAction {
        switch consume self.state {
        case .initialized(let initializedState):
            switch initializedState.type {
            case .client:
                // Need to make sure server isn't quiescing
                switch initializedState.quiescingState.createOutboundRequestStream() {
                case .create:
                    self = .init(state: .initialized(initializedState))
                    return .create
                case .failToCreate(let error):
                    self = .init(state: .initialized(initializedState))
                    return .failedToCreateStream(error)
                }
            case .server:
                self = .init(state: .initialized(initializedState))
                return .failedToCreateStream(
                    HTTP3Error(
                        code: .streamCreationError,
                        message: "Unable to make outbound request stream",
                        cause: nil,
                        errorCode: nil,
                        location: .here()
                    )
                )
            }
        case .notStarted:
            fatalError("Outbound request stream requested before state machine started")
        case .finished:
            self = .init(state: .finished)
            return .failedToCreateStream(
                HTTP3Error(
                    code: .streamCreationError,
                    message: "Connection already closed",
                    cause: nil,
                    errorCode: nil,
                    location: .here()
                )
            )
        }
    }

    package mutating func outboundRequestStreamReady(streamID: QUICStreamID) {
        precondition(streamID.isBidirectional)
        switch consume self.state {
        case .notStarted:
            fatalError("Outbound request stream created before state machine started")
        case .initialized(var initializedState):
            switch initializedState.type {
            case .server:
                preconditionFailure("Servers can't create request streams")
            case .client:
                initializedState.streamIDTracker.streamOpened(id: streamID)
                self = .init(state: .initialized(initializedState))
            }
        case .finished:
            self = .init(state: .finished)
        }
    }

    package mutating func outboundControlStreamReady(streamID: QUICStreamID) {
        precondition(streamID.isUnidirectional)
        switch consume self.state {
        case .notStarted:
            fatalError("Outbound request stream created before state machine started")
        case .initialized(var initializedState):
            initializedState.streamIDTracker.streamOpened(id: streamID)
            self = .init(state: .initialized(initializedState))
        case .finished:
            self = .init(state: .finished)
        }
    }

    // MARK: Control stream

    package enum ControlFrameReceivedAction {
        /// An outbound QPACK encoder instruction stream needs to be created.
        case makeEncoderInstructionStream
        /// A connection error should be emitted
        case emitConnectionError(HTTP3Error)
        /// The following streams should be cancelled (we got a GOAWAY)
        case cancelStreams(ids: [QUICStreamID])
        /// The connection should be immediately closed without an error.
        case closeConnection
    }

    package mutating func receivedControlFrame(_ frame: HTTP3Frame) -> ControlFrameReceivedAction? {
        switch frame {
        case .settings(let payload):
            let settings = payload.settings
            switch consume self.state {
            case .initialized(var initializedState):
                let action = initializedState.qpackState.receivedRemoteSettings(
                    maxQueueSize: Int(clamping: settings.qpackBlockedStreams),
                    effectiveDynamicTableSize: initializedState.localDynamicTableSize == 0
                        ? 0 : Int(clamping: settings.qpackMaximumTableCapacity)
                )
                self = .init(state: .initialized(initializedState))
                switch action {
                case .makeEncoderInstructionStream:
                    return .makeEncoderInstructionStream
                case .none:
                    return nil
                }
            case .notStarted:
                fatalError("Inbound control frame received before state machine started")
            case .finished:
                // Drop incoming frames now since we already closed
                self = .init(state: .finished)
                return .none
            }
        case .data, .headers, .pushPromise:
            // The frame validator will prevent this
            fatalError("Invalid frame for control stream")
        case .goaway(let payload):
            let newRemoteGoawayID = payload.id
            switch consume self.state {
            case .initialized(var initializedState):
                switch initializedState.quiescingState.receivedGoaway(newGoawayID: newRemoteGoawayID) {
                case .cancelStreamsOrCloseIfNone(let newMaxStreamID):
                    // Requests equal to or above the indicated ID are cancelled
                    let idsToCancel = initializedState.streamIDTracker.getOpenStreamIDs {
                        $0 >= newMaxStreamID && $0.isBidirectional && $0.isClientInitiated
                    }
                    let hasOpenRequestStreams = initializedState.streamIDTracker.hasOpenRequestStreams()
                    self = .init(state: .initialized(initializedState))
                    if idsToCancel.isEmpty {
                        if hasOpenRequestStreams {
                            // Can't close because we have requests in flight. We'll check again on stream close.
                            return .none
                        } else {
                            // We are a client, we were told to go away, and nothing is in flight
                            return .closeConnection
                        }
                    } else {
                        // There is stuff to be cancelled
                        return .cancelStreams(ids: idsToCancel)
                    }
                case .emitConnectionError(let error):
                    self = .init(state: .finished)
                    return .emitConnectionError(error)
                case .none:
                    // Keep state as it was
                    self = .init(state: .initialized(initializedState))
                    return .none
                }
            case .notStarted:
                fatalError("Received control frame before connection initialized")
            case .finished:
                // Drop incoming frames now since we already closed
                self = .init(state: .finished)
                return .none
            }
        case .maxPushID:
            switch consume self.state {
            case .initialized(let initializedState):
                switch initializedState.type {
                case .client:
                    // RFC 9114 § 7.2.7: A server MUST NOT send a MAX_PUSH_ID frame.
                    // A client MUST treat the receipt of a MAX_PUSH_ID frame as a connection error of type H3_FRAME_UNEXPECTED.
                    self = .init(state: .finished)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Received MAX_PUSH_ID on client",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                case .server:
                    // TODO: https://github.com/apple/swift-nio-http3/issues/1
                    // Drop push-related stuff for now.
                    self = .init(state: .initialized(initializedState))
                    return nil
                }
            case .notStarted:
                fatalError("Received control frame before connection initialized")
            case .finished:
                // Drop incoming frames now since we already closed
                self = .init(state: .finished)
                return .none
            }
        case .cancelPush:
            // TODO: https://github.com/apple/swift-nio-http3/issues/1
            // Drop push-related stuff for now.
            return nil
        }
    }

    // MARK: QPACK

    package enum IncomingEncoderInstructionAction {
        /// The new incoming instruction resulted in previously-blocked headers now being decodable.
        case sendDecoderInstruction(QPACKDecoderInstruction)
        case emitConnectionError(HTTP3Error)
    }

    /// Inform the state machine of a new incoming QPACK encoder instruction. After this, you should call ``checkPendingDecodes()`` because the new instruction
    /// may have unblocked a pending decode.
    package mutating func receivedIncomingEncoderInstruction(
        _ instruction: QPACKEncoderInstruction
    ) -> IncomingEncoderInstructionAction? {
        switch consume self.state {
        case .notStarted:
            fatalError("Inbound encoder instruction received before state machine started")
        case .finished:
            // Drop incoming now since we already closed
            self = .init(state: .finished)
            return nil
        case .initialized(var initializedState):
            let result = initializedState.qpackState.receivedIncomingEncoderInstruction(instruction)
            switch result {
            case .emitConnectionError(let error):
                self = .init(state: .finished)
                return .emitConnectionError(error)
            case .sendDecoderInstruction(let instruction):
                self = .init(state: .initialized(initializedState))
                return .sendDecoderInstruction(instruction)
            case .none:
                self = .init(state: .initialized(initializedState))
                return .none
            }
        }
    }

    package enum IncomingDecoderInstructionAction {
        case emitConnectionError(HTTP3Error)
    }

    package mutating func receivedIncomingDecoderInstruction(
        _ instruction: QPACKDecoderInstruction
    ) -> IncomingDecoderInstructionAction? {
        switch consume self.state {
        case .notStarted:
            fatalError("Inbound decoder instruction received before state machine started")
        case .finished:
            // Drop incoming now since we already closed
            self = .init(state: .finished)
            return nil
        case .initialized(var initializedState):
            let result = initializedState.qpackState.receivedIncomingDecoderInstruction(instruction)
            switch result {
            case .emitConnectionError(let error):
                self = .init(state: .finished)
                return .emitConnectionError(error)
            case .none:
                self = .init(state: .initialized(initializedState))
                return .none
            }
        }
    }

    package mutating func encodeHeaders(_ headers: [HTTPField], forStream streamID: QUICStreamID) -> QPACKEncodeResult {
        switch consume self.state {
        case .notStarted:
            fatalError("Tried to encode headers before state machine started")
        case .finished:
            fatalError("Tried to encode headers after state machine finished")
        case .initialized(var initializedState):
            let result = initializedState.qpackState.encodeHeaders(headers, forStream: streamID)
            self = .init(state: .initialized(initializedState))
            return result
        }
    }

    package enum DecodeHeaderAction {
        /// Send this qpack decode result to the relevant stream.
        case informDecodeResult(InformDecodeResult)

        /// Send this qpack decoder error to the relevant stream. This is a stream-level error.
        case informDecodeError(InformDecodeError)

        /// Send a connection-level error.
        case emitConnectionError(HTTP3Error)
        package struct InformDecodeResult: Hashable, Sendable {
            package var fields: [HTTPField]
            package var headers: HTTP3PartialFrame.Headers
            package var streamID: QUICStreamID
            package var instructionToWrite: QPACKDecoderInstruction?

            package init(
                fields: [HTTPField],
                headers: HTTP3PartialFrame.Headers,
                streamID: QUICStreamID,
                instructionToWrite: QPACKDecoderInstruction?
            ) {
                self.fields = fields
                self.headers = headers
                self.streamID = streamID
                self.instructionToWrite = instructionToWrite
            }
        }

        package struct InformDecodeError {
            package var error: HTTP3Error
            package var headers: HTTP3PartialFrame.Headers
            package var streamID: QUICStreamID

            package init(error: HTTP3Error, headers: HTTP3PartialFrame.Headers, streamID: QUICStreamID) {
                self.error = error
                self.headers = headers
                self.streamID = streamID
            }
        }

        init(_ informDecodeResult: QPACKStateMachine.DecodeHeaderAction) {
            switch informDecodeResult {
            case .emitConnectionError(let error):
                self = .emitConnectionError(error)
            case .informDecodeError(let error):
                self = .informDecodeError(.init(error: error.error, headers: error.headers, streamID: error.streamID))
            case .informDecodeResult(let result):
                self = .informDecodeResult(
                    .init(
                        fields: result.fields,
                        headers: result.headers,
                        streamID: result.streamID,
                        instructionToWrite: result.instructionToWrite
                    )
                )
            }
        }
    }

    package mutating func decodeHeaders(
        _ header: HTTP3PartialFrame.Headers,
        forStream streamID: QUICStreamID
    ) -> DecodeHeaderAction? {
        switch consume self.state {
        case .notStarted:
            fatalError("Tried to decode headers before state machine started")
        case .finished:
            // Ignore this
            self = .init(state: .finished)
            return nil
        case .initialized(var initializedState):
            let action = initializedState.qpackState.decodeHeaders(header, forStream: streamID)
            self = .init(state: .initialized(initializedState))
            return action.map { .init($0) }
        }
    }

    /// Check if any previously-queued decode is now decodable.
    /// This function should be called repeatedly after new input (eg. new incoming instructions) until it returns nil
    package mutating func checkPendingQPACKDecodes() -> DecodeHeaderAction? {
        switch consume self.state {
        case .notStarted:
            fatalError("Tried to decode headers before state machine started")
        case .finished:
            self = .init(state: .finished)
            return nil
        case .initialized(var initializedState):
            let action = initializedState.qpackState.checkPendingDecodes()
            self = .init(state: .initialized(initializedState))
            return action.map { .init($0) }
        }
    }

    // MARK: Shutdown

    package enum CloseAction {
        /// Send a GOAWAY frame containing ``id`` and close any existing streams with an id in ``idsToCancel``
        case sendGoaway(id: HTTP3GoawayID, idsToCancel: [QUICStreamID])
        /// Throw an error: the caller of this function has made a mistake and gave us an invalid id.
        case throwError(any Error)
        /// Close the connection immediately.
        case closeImmediately
    }

    /// Whether a graceful shutdown can be initiated by this endpoint.
    ///
    /// Returns `false` if the connection is not yet open or has already finished, or if a graceful shutdown has already
    /// been initiated.
    package func canInitiateGracefulShutdown() -> Bool {
        switch self.state {
        case .notStarted:
            return false

        case .finished:
            return false

        case .initialized(let initializedState):
            return initializedState.quiescingState.canInitiateGracefulShutdown()
        }
    }

    package mutating func sendGoaway(goawayID newLocalMaxID: HTTP3GoawayID) -> CloseAction? {
        switch consume self.state {
        case .notStarted:
            self = .init(state: .finished)
            return .closeImmediately
        case .finished:
            self = .init(state: .finished)
            return nil
        case .initialized(var initializedState):
            let action = initializedState.quiescingState.sendGoaway(goawayID: newLocalMaxID)

            let idsToCancel: [QUICStreamID]
            switch initializedState.type {
            case .client:
                // TODO: Once we implement server push, explicitly cancel pushes above the max ID here
                idsToCancel = []
            case .server:
                // RFC 9114 § 5.2: Upon sending a GOAWAY frame, the endpoint SHOULD explicitly cancel (see Sections 4.1.1 and 7.2.3) any requests or
                // pushes that have identifiers greater than or equal to the one indicated, in order to clean up transport state for the affected streams
                let sentID = QUICStreamID(goawayID: newLocalMaxID)
                idsToCancel = initializedState.streamIDTracker.getOpenStreamIDs {
                    $0 >= sentID && $0.isBidirectional && $0.isClientInitiated
                }
            }
            self = .init(state: .initialized(initializedState))
            switch action {
            case .throwError(let error):
                return .throwError(error)
            case .sendGoaway(let id):
                return .sendGoaway(id: id, idsToCancel: idsToCancel)
            }
        }
    }

    /// Returns the next expected client-initiated bidirectional stream ID, or `nil` if the connection is not in the
    /// `.initialized` state.
    package func nextExpectedClientInitiatedBidirectionalStreamID() -> QUICStreamID? {
        switch self.state {
        case .notStarted:
            return nil

        case .finished:
            return nil

        case .initialized(let initializedState):
            return initializedState.streamIDTracker.nextExpectedClientInitiatedBidirectionalStreamID()
        }
    }

    package enum StreamClosedAction {
        case sendDecoderInstruction(QPACKDecoderInstruction, shouldCloseConnection: Bool)
        case closeConnection
        case emitConnectionError(HTTP3Error)
    }

    /// Call this to tell the machine that a stream has been closed. Will drop pending QPACK decodes and perform other cleanup.
    /// - Parameters:
    ///   - streamID: The ID of the stream which was closed.
    ///   - seenEOF: Whether or not we saw an input close before the stream closed. That means we didn't drop any incoming data.
    ///   - streamType: The type of the stream which was closed.
    /// - Returns: The next action to take.
    package mutating func streamClosed(
        streamID: QUICStreamID,
        seenEOF: Bool,
        streamType: HTTP3StreamType
    ) -> StreamClosedAction? {
        switch consume self.state {
        case .notStarted:
            fatalError("Stream closed before connection initialized")
        case .initialized(var initializedState):
            switch streamType {
            case .request:
                let qpackAction = initializedState.qpackState.requestStreamClosed(streamID: streamID, seenEOF: seenEOF)
                if !initializedState.streamIDTracker.streamClosed(id: streamID) {
                    assertionFailure(
                        "[\(initializedState.type)] Trying to remove a non existent stream \(streamID) from tracker"
                    )
                }
                let hasOpenStreams = initializedState.streamIDTracker.hasOpenRequestStreams()
                switch initializedState.quiescingState.shouldCloseConnection() {
                case .closeIfNoOpenStreams:
                    self = .init(state: .initialized(initializedState))
                    switch qpackAction {
                    case .sendDecoderInstruction(let instructions):
                        return .sendDecoderInstruction(instructions, shouldCloseConnection: !hasOpenStreams)
                    case .none:
                        if hasOpenStreams {
                            return .none
                        } else {
                            return .closeConnection
                        }
                    }
                case .closeIfExhaustedStreamsAndNonOpen(let maxID):
                    let hasExhaustedStreams = initializedState.streamIDTracker.hasExhaustedSameTypeStreams(
                        withIDsLessThan: maxID
                    )
                    self = .init(state: .initialized(initializedState))
                    switch qpackAction {
                    case .sendDecoderInstruction(let instructions):
                        return .sendDecoderInstruction(instructions, shouldCloseConnection: !hasOpenStreams)
                    case .none:
                        if !hasOpenStreams && hasExhaustedStreams {
                            return .closeConnection
                        } else {
                            return .none
                        }
                    }
                case .doNotClose:
                    self = .init(state: .initialized(initializedState))
                    switch qpackAction {
                    case .sendDecoderInstruction(let instructions):
                        return .sendDecoderInstruction(instructions, shouldCloseConnection: !hasOpenStreams)
                    case .none:
                        return .none
                    }
                }
            case .unidirectional(let unidirectionalStreamType):
                if !initializedState.streamIDTracker.streamClosed(id: streamID) {
                    assertionFailure(
                        "[\(initializedState.type)] Trying to remove a non existent stream \(streamID) \(streamType) from tracker"
                    )
                }

                switch unidirectionalStreamType {
                case .control, .qpackEncoder, .qpackDecoder:
                    // RFC 9114 § 6.2.1: If either control stream is closed at any point, this MUST be treated as a connection error of type H3_CLOSED_CRITICAL_STREAM.
                    // RFC 9204 § 4.2: Closure of either [QPACK] unidirectional stream type MUST be treated as a connection error of type H3_CLOSED_CRITICAL_STREAM.
                    let typeName =
                        switch streamID.type {
                        case .serverInitiatedBidirectional, .serverInitiatedUnidirectional: "server-initiated"
                        case .clientInitiatedBidirectional, .clientInitiatedUnidirectional: "client-initiated"
                        }
                    self = .init(state: .finished)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .criticalStreamClosed,
                            message: "The \(typeName) \(unidirectionalStreamType) stream was closed",
                            cause: nil,
                            errorCode: .H3_CLOSED_CRITICAL_STREAM,
                            location: .here()
                        )
                    )
                case .push, .unknown:
                    self = .init(state: .initialized(initializedState))
                }
                return nil
            }
        case .finished:
            // We don't care about tracking streams anymore (in fact, we can't). Just ignore it
            self = .init(state: .finished)
            return nil
        }
    }

    package enum ShutdownCompleteAction: Hashable {
        /// The connection should be closed now
        case shutdown
    }

    /// Call this when the connection has been completely shut down for any reason.
    package mutating func shutdownConnectionImmediately() -> ShutdownCompleteAction {
        // TODO: verify that we really did close all bidi streams?
        // There will still be open streams here if the connection channel was closed suddenly rather than gracefully.
        self = .init(state: .finished)
        return .shutdown
    }

    /// Assert that there are no open streams right now.
    package func assertNoOpenStreams(logger: Logger) {
        switch self.state {
        case .initialized(let initialized):
            let openStreams = initialized.streamIDTracker.openStreams
            if !openStreams.isEmpty {
                logger.debug("Unexpected open streams \(openStreams)")
                assertionFailure()
            }
        default:
            break
        }
    }

    package enum EmitConnectionErrorAction {
        case emitConnectionError(HTTP3Error)
        case none
    }

    /// Call this when a stream wants to emit a connection-level error.
    package mutating func emitConnectionErrorFromStream(error: HTTP3Error) -> EmitConnectionErrorAction {
        switch consume self.state {
        case .finished:
            // We already finished, so emitting a connection error is now pointless.
            self = .init(state: .finished)
            return .none
        case .initialized:
            self = .init(state: .finished)
            return .emitConnectionError(error)
        case .notStarted:
            fatalError("Stream emitted connection error before started")
        }
    }

    package enum CaughtRemoteErrorAction {
        /// Cancel these streams because the remote closed the connection.
        case cancelStreams([QUICStreamID])
    }

    /// Call this when the remote sends us an error.
    package mutating func caughtRemoteError(_: HTTP3Error) -> CaughtRemoteErrorAction? {
        switch consume self.state {
        case .initialized(let initializedState):
            let idsToCancel = initializedState.streamIDTracker.getOpenStreamIDs {
                $0.isBidirectional
            }
            self = .init(state: .finished)
            return .cancelStreams(idsToCancel)
        case .notStarted:
            self = .init(state: .finished)
            return nil
        case .finished:
            self = .init(state: .finished)
            return nil
        }
    }
}

extension HTTP3Error {
    fileprivate static func rejectIncomingStreamDueToShuttingDown(location: SourceLocation) -> Self {
        .init(
            code: .streamCreationError,
            message: "Endpoint is shutting down",
            cause: nil,
            errorCode: .H3_STREAM_CREATION_ERROR,
            location: location
        )
    }
}
