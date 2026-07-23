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

package import NIOQUICHelpers

package struct HTTP3ConnectionQuiescingStateMachine: ~Copyable {
    private enum State: ~Copyable {
        /// Neither side has started quiescing yet.
        case notQuiesced(NotQuiesced)

        /// We have sent a GOAWAY but not received one.
        case locallyQuiesced(LocallyQuiesced)

        /// We have received a GOAWAY but not sent one.
        case remotelyQuiesced(RemotelyQuiesced)

        /// We have sent and received a GOAWAY.
        case bothQuiesced(BothQuiesced)

        struct NotQuiesced: ~Copyable {
            let type: HTTP3ConnectionType
        }

        struct LocallyQuiesced: ~Copyable {
            /// The ID that we sent. We'll accept requests/pushes with IDs below this.
            let goawayID: HTTP3GoawayID
            let type: HTTP3ConnectionType

            /// Start locally quiescing when previously not quiesced at all
            init(notQuiesced: consuming NotQuiesced, newID: HTTP3GoawayID) {
                self.goawayID = newID
                self.type = notQuiesced.type
            }

            /// Reduce the ID when we were already locally quiescing
            init(locallyQuiesced: consuming LocallyQuiesced, newID: HTTP3GoawayID) {
                self.goawayID = newID
                self.type = locallyQuiesced.type
            }
        }

        struct RemotelyQuiesced: ~Copyable {
            /// The ID that they sent. They'll accept requests/pushes with IDs below this.
            let goawayID: HTTP3GoawayID
            let type: HTTP3ConnectionType

            /// Start remotely quiescing when previously not quiesced at all
            init(notQuiesced: consuming NotQuiesced, newID: HTTP3GoawayID) {
                self.goawayID = newID
                self.type = notQuiesced.type
            }

            /// Reduce the ID when we were already remotely quiescing
            init(remotelyQuiesced: consuming RemotelyQuiesced, newID: HTTP3GoawayID) {
                self.goawayID = newID
                self.type = remotelyQuiesced.type
            }
        }

        struct BothQuiesced: ~Copyable {
            /// The ID that we sent. We'll accept requests/pushes with IDs below this.
            let localGoawayID: HTTP3GoawayID
            /// The ID that they sent. They'll accept requests/pushes with IDs below this.
            let remoteGoawayID: HTTP3GoawayID
            let type: HTTP3ConnectionType

            /// Start remotely quiescing when previously only locally quiesced
            init(locallyQuiesced: consuming LocallyQuiesced, remoteGoawayID: HTTP3GoawayID) {
                self.localGoawayID = locallyQuiesced.goawayID
                self.remoteGoawayID = remoteGoawayID
                self.type = locallyQuiesced.type
            }

            /// Start locally quiescing when previously only remotely quiesced
            init(remotelyQuiesced: consuming RemotelyQuiesced, localGoawayID: HTTP3GoawayID) {
                self.remoteGoawayID = remotelyQuiesced.goawayID
                self.localGoawayID = localGoawayID
                self.type = remotelyQuiesced.type
            }

            /// Reduce the local ID when we were already quiescing on both ends
            init(bothQuiesced: consuming BothQuiesced, newLocalGoawayID: HTTP3GoawayID) {
                self.remoteGoawayID = bothQuiesced.remoteGoawayID
                self.localGoawayID = newLocalGoawayID
                self.type = bothQuiesced.type
            }

            /// Reduce the max ID when we were already quiescing on both ends
            init(bothQuiesced: consuming BothQuiesced, newRemoteGoawayID: HTTP3GoawayID) {
                self.remoteGoawayID = newRemoteGoawayID
                self.localGoawayID = bothQuiesced.localGoawayID
                self.type = bothQuiesced.type
            }
        }
    }

    private let state: State

    private init(state: consuming State) {
        self.state = state
    }

    package init(type: HTTP3ConnectionType) {
        self.init(state: .notQuiesced(.init(type: type)))
    }

    package enum ReceivedGoawayAction {
        /// Streams with ids equal to or above the given id should be cancelled. If there are no such streams, the connection should be closed.
        case cancelStreamsOrCloseIfNone(lowestIDToCancel: QUICStreamID)
        case emitConnectionError(HTTP3Error)
    }

    private var connectionType: HTTP3ConnectionType {
        switch self.state {
        case .notQuiesced(let notQuiesced):
            return notQuiesced.type
        case .locallyQuiesced(let locallyQuiesced):
            return locallyQuiesced.type
        case .remotelyQuiesced(let remotelyQuiesced):
            return remotelyQuiesced.type
        case .bothQuiesced(let bothQuiesced):
            return bothQuiesced.type
        }
    }

    /// Whether a graceful shutdown can be initiated by this endpoint.
    ///
    /// Returns `false` if a graceful shutdown has already been initiated previously.
    func canInitiateGracefulShutdown() -> Bool {
        switch self.state {
        case .notQuiesced:
            return true

        case .remotelyQuiesced:
            return true

        case .locallyQuiesced:
            // We already sent a GOAWAY before.
            return false

        case .bothQuiesced:
            // Same as the `locallyQuiesced` state above.
            return false
        }
    }

    package mutating func receivedGoaway(newGoawayID: HTTP3GoawayID) -> ReceivedGoawayAction? {
        @inline(never)
        func invalidGoawayStreamIDError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
            HTTP3Error(
                code: .invalidGoawayStreamID,
                message: "Invalid GOAWAY id",
                cause: nil,
                errorCode: .idError,
                location: location
            )
        }
        switch self.connectionType {
        case .client:
            // We are a client. Server sent a goaway. Should be the ID of a request stream.
            let lowestIDToCancel = QUICStreamID(goawayID: newGoawayID)
            guard lowestIDToCancel.isClientInitiated && lowestIDToCancel.isBidirectional else {
                // Keep state as it was
                return .emitConnectionError(invalidGoawayStreamIDError(location: .here()))
            }
            switch consume self.state {
            case .notQuiesced(let notQuiescedState):
                self = .init(state: .remotelyQuiesced(.init(notQuiesced: notQuiescedState, newID: newGoawayID)))
                // If nothing open we should close because we're a client and got told to goaway
                return .cancelStreamsOrCloseIfNone(lowestIDToCancel: lowestIDToCancel)

            case .remotelyQuiesced(let remotelyQuiescedState):
                if remotelyQuiescedState.goawayID < newGoawayID {
                    // Increasing the goaway id is always an error. Retain state and throw error
                    self = .init(state: .remotelyQuiesced(remotelyQuiescedState))
                    return .emitConnectionError(.goawayIDIncreased(location: .here()))
                }

                // Peer has reduced the max stream id. That's fine.
                self = .init(
                    state: .remotelyQuiesced(.init(remotelyQuiesced: remotelyQuiescedState, newID: newGoawayID))
                )
                // If nothing open we should close because we're a client and got told to goaway
                return .cancelStreamsOrCloseIfNone(lowestIDToCancel: lowestIDToCancel)

            case .bothQuiesced(let bothQuiescedState):
                if bothQuiescedState.remoteGoawayID < newGoawayID {
                    // Increasing the goaway id is always an error. Retain state and throw error
                    self = .init(state: .bothQuiesced(bothQuiescedState))
                    return .emitConnectionError(.goawayIDIncreased(location: .here()))
                }

                // Peer has reduced the max stream id. That's fine.
                self = .init(
                    state: .bothQuiesced(.init(bothQuiesced: bothQuiescedState, newRemoteGoawayID: newGoawayID))
                )
                // If nothing open we should close because we're a client and got told to goaway
                return .cancelStreamsOrCloseIfNone(lowestIDToCancel: lowestIDToCancel)

            case .locallyQuiesced(let locallyQuiescedState):
                // They haven't sent us a goaway before
                self = .init(
                    state: .bothQuiesced(.init(locallyQuiesced: locallyQuiescedState, remoteGoawayID: newGoawayID))
                )
                // If nothing open we should close because we're a client and got told to goaway
                return .cancelStreamsOrCloseIfNone(lowestIDToCancel: lowestIDToCancel)
            }
        case .server:
            // We are a server. Client sent a goaway. Should be a push ID.
            // Record it, so we can enforce that they don't send another goaway with a higher ID.
            // There is no actual action to take right now, because we don't support pushes anyway.
            // TODO: maybe some changes to make here once we implement server push.
            switch consume self.state {
            case .notQuiesced(let notQuiescedState):
                self = .init(state: .remotelyQuiesced(.init(notQuiesced: notQuiescedState, newID: newGoawayID)))
                return .none

            case .remotelyQuiesced(let remotelyQuiescedState):
                if remotelyQuiescedState.goawayID < newGoawayID {
                    // Increasing the goaway id is always an error. Retain state and throw error
                    self = .init(state: .remotelyQuiesced(remotelyQuiescedState))
                    return .emitConnectionError(.goawayIDIncreased(location: .here()))
                }

                // Peer has reduced the max stream id. That's fine.
                self = .init(
                    state: .remotelyQuiesced(.init(remotelyQuiesced: remotelyQuiescedState, newID: newGoawayID))
                )
                return .none

            case .bothQuiesced(let bothQuiescedState):
                if bothQuiescedState.remoteGoawayID < newGoawayID {
                    // Increasing the goaway id is always an error. Retain state and throw error
                    self = .init(state: .bothQuiesced(bothQuiescedState))
                    return .emitConnectionError(.goawayIDIncreased(location: .here()))
                }

                // Peer has reduced the max stream id. That's fine.
                self = .init(
                    state: .bothQuiesced(.init(bothQuiesced: bothQuiescedState, newRemoteGoawayID: newGoawayID))
                )
                return .none

            case .locallyQuiesced(let locallyQuiescedState):
                // They haven't sent us a goaway before
                self = .init(
                    state: .bothQuiesced(.init(locallyQuiesced: locallyQuiescedState, remoteGoawayID: newGoawayID))
                )
                return .none
            }
        }
    }

    package enum SendGoawayAction {
        /// Write a GOAWAY frame
        case sendGoaway(id: HTTP3GoawayID)
        /// Throw an error: the caller of this function has made a mistake and gave us an invalid id.
        case throwError(HTTP3Error)
    }

    package mutating func sendGoaway(goawayID: HTTP3GoawayID) -> SendGoawayAction {
        switch self.connectionType {
        case .client:
            // We are sending the server a goaway, so the id represents a push id.
            // Any integer is fine here (HTTP3GoawayID already enforces basic constraints like ≥ 0)
            break
        case .server:
            // We are sending the client a goaway, so the id represents a stream id.
            // This ID must be that of a client-initiated, bidirectional stream (i.e. a request stream)
            let externalStreamID = QUICStreamID(goawayID: goawayID)
            guard externalStreamID.isBidirectional && externalStreamID.isClientInitiated else {
                return .throwError(
                    HTTP3Error(
                        code: .invalidGoawayStreamID,
                        message: "\(goawayID) is not a client-initiated bidirectional stream ID",
                        cause: nil,
                        errorCode: nil,
                        location: .here()
                    )
                )
            }
        }
        switch consume self.state {
        case .notQuiesced(let notQuiescedState):
            // Previously not quiescing. Start local quiescing and send a goaway to the remote.
            self = .init(state: .locallyQuiesced(.init(notQuiesced: notQuiescedState, newID: goawayID)))
            return .sendGoaway(id: goawayID)

        case .remotelyQuiesced(let remotelyQuiescedState):
            // Previously remotely quiescing but not locally quiescing. New state is both quiescing.
            self = .init(
                state: .bothQuiesced(.init(remotelyQuiesced: remotelyQuiescedState, localGoawayID: goawayID))
            )
            return .sendGoaway(id: goawayID)

        case .locallyQuiesced(let locallyQuiescedState):
            // Was already locally quiescing. We can reduce the stream id but can't increase it.
            guard goawayID <= locallyQuiescedState.goawayID else {
                // This isn't allowed, we'll ignore it and keep our state
                self = .init(state: .locallyQuiesced(locallyQuiescedState))
                return .throwError(.goawayIDIncreased(location: .here()))
            }
            self = .init(state: .locallyQuiesced(.init(locallyQuiesced: locallyQuiescedState, newID: goawayID)))
            return .sendGoaway(id: goawayID)

        case .bothQuiesced(let bothQuiescedState):
            // Both ends were already quiescing. We can reduce our stream id but can't increase it.
            guard goawayID <= bothQuiescedState.localGoawayID else {
                // This isn't allowed, we'll ignore it and keep our state
                self = .init(state: .bothQuiesced(bothQuiescedState))
                return .throwError(.goawayIDIncreased(location: .here()))
            }
            self = .init(state: .bothQuiesced(.init(bothQuiesced: bothQuiescedState, newLocalGoawayID: goawayID)))
            return .sendGoaway(id: goawayID)
        }
    }

    package enum ShouldCloseConnectionAction: Hashable {
        /// The connection should be closed if there are no open streams.
        case closeIfNoOpenStreams
        /// The connection should be closed if there are no open streams AND there can be no more streams below maxID (we already exhausted all the numbers).
        case closeIfExhaustedStreamsAndNonOpen(maxID: QUICStreamID)
        /// The connection should not be closed.
        case doNotClose
    }

    /// Determines whether or not to close the connection, and under which conditions.
    /// Call this whenever a request stream closes. It might be that it was the last one we were waiting for before closing the connection.
    package func shouldCloseConnection() -> ShouldCloseConnectionAction {
        switch self.state {
        case .notQuiesced:
            // Neither side has quiesced, so there is nothing to do
            return .doNotClose

        case .locallyQuiesced(let locallyQuiescedState):
            switch locallyQuiescedState.type {
            case .client:
                // We are a client, we initiated a goaway. That means we don't accept new incoming push streams from the server.
                // We can still make as many outbound requests as we want. Therefore, even if we're idle, that's fine
                return .doNotClose
            case .server:
                // We are a server and we asked the client to go away. There are currently no open streams. But they might
                // be sending us a stream that we haven't seen yet.
                // We need to check if they maybe already exhausted all IDs above the max that we sent
                let maxStreamID = QUICStreamID(goawayID: locallyQuiescedState.goawayID)
                return .closeIfExhaustedStreamsAndNonOpen(maxID: maxStreamID)
            }

        case .remotelyQuiesced(let remotelyQuiescedState):
            // They initiated a shutdown. We have not sent a goaway.
            switch remotelyQuiescedState.type {
            case .client:
                // We are a client, and we got told to goaway. If we have no open streams, it's time to close.
                return .closeIfNoOpenStreams
            case .server:
                // We are a server and we got told to go away. But we didn't tell the client to go away.
                // Client should be allowed to make new requests still.
                return .doNotClose
            }

        case .bothQuiesced(let bothQuiescedState):
            switch bothQuiescedState.type {
            case .client:
                // We are a client, and we got told to goaway. If we have no open streams, it's time to close.
                return .closeIfNoOpenStreams
            case .server:
                // We are a server and we asked the client to go away. There are currently no open streams. But they might
                // be sending us a stream that we haven't seen yet.
                // We need to check if they maybe already exhausted all IDs above the max that we sent
                let maxStreamID = QUICStreamID(goawayID: bothQuiescedState.localGoawayID)
                return .closeIfExhaustedStreamsAndNonOpen(maxID: maxStreamID)
            }
        }
    }

    package func inboundRequestStreamAllowed(incomingStreamID: QUICStreamID) -> Bool {
        switch self.state {
        case .notQuiesced: return true
        case .remotelyQuiesced: return true
        case .bothQuiesced(let bothQuiescedState):
            // Incoming streamID must be less than the id indicated in the GOAWAY which we sent
            return incomingStreamID < QUICStreamID(goawayID: bothQuiescedState.localGoawayID)
        case .locallyQuiesced(let locallyQuiescedState):
            return incomingStreamID < QUICStreamID(goawayID: locallyQuiescedState.goawayID)
        }
    }

    package enum CreateOutboundRequestStreamAction {
        case create
        case failToCreate(HTTP3Error)
    }

    package func createOutboundRequestStream() -> CreateOutboundRequestStreamAction {
        switch self.state {
        case .notQuiesced: return .create
        case .locallyQuiesced: return .create
        case .remotelyQuiesced: return .failToCreate(.requestStreamAfterGoaway(location: .here()))
        case .bothQuiesced: return .failToCreate(.requestStreamAfterGoaway(location: .here()))
        }
    }
}

extension HTTP3Error {
    fileprivate static func goawayIDIncreased(location: SourceLocation) -> HTTP3Error {
        // RFC 9114 § 5.2: Receiving a GOAWAY containing a larger identifier than previously received MUST be treated as a connection error of type H3_ID_ERROR.
        HTTP3Error(
            code: .invalidGoawayStreamID,
            message: "GOAWAY id was increased",
            cause: nil,
            errorCode: .idError,
            location: location
        )
    }

    fileprivate static func requestStreamAfterGoaway(location: SourceLocation) -> HTTP3Error {
        // RFC 9114 § 5.2: Receiving a GOAWAY containing a larger identifier than previously received MUST be treated as a connection error of type H3_ID_ERROR.
        HTTP3Error(
            code: .streamCreationError,
            message: "Cannot create request stream after receiving a GOAWAY",
            cause: nil,
            errorCode: nil,
            location: location
        )
    }
}
