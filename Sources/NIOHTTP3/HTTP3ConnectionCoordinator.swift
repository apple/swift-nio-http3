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

@_spi(PackageInternal) import HTTP3
import HTTPTypes
import Logging
import NIOCore
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK

/// This class owns the connection state machine and is responsible for opening streams and sending frames.
/// I.e. it coordinates everything across the connection, including qpack.
final class HTTP3ConnectionCoordinator<QUICStreamCreator: NIOQUICHelpers.QUICStreamCreator> {
    let eventLoop: any EventLoop
    private var connectionStateMachine: HTTP3ConnectionStateMachine
    private let outboundQPACKEncoderHandler: QPACKOutboundEncoderStreamHandler
    private let outboundQPACKDecoderHandler: QPACKOutboundDecoderStreamHandler
    private let outboundControlStreamHandler: HTTP3OutboundControlStreamHandler
    private let streamCreator: QUICStreamCreator
    /// The connection handler.
    ///
    /// Setting this creates a strong retain cycle which is broken by the connection handler when
    /// it's removed from the channel pipeline.
    private var connection: HTTP3ConnectionHandler<QUICStreamCreator>?
    private let preferHuffmanEncoding: Bool
    private let logger: Logger
    /// Instances of stream handlers which need to be pinged whenever a dynamic table entry is added.
    private var streamHandlers = [QUICStreamID: HTTP3StreamHandler<HTTP3ConnectionCoordinator<QUICStreamCreator>>]()
    private var datagramBuffer: HTTP3DatagramBuffer

    init(
        eventLoop: any EventLoop,
        localSettings: HTTP3Settings,
        streamCreator: QUICStreamCreator,
        type: HTTP3ConnectionType,
        preferHuffmanEncoding: Bool,
        maxBufferedDatagramBytes: Int,
        logger: Logger,
    ) {
        precondition(maxBufferedDatagramBytes >= 0)
        self.eventLoop = eventLoop
        self.outboundQPACKDecoderHandler = .init()
        self.outboundQPACKEncoderHandler = .init()
        self.outboundControlStreamHandler = .init(settings: localSettings)
        self.connectionStateMachine = .init(settings: localSettings, type: type)
        self.streamCreator = streamCreator
        self.logger = logger
        self.preferHuffmanEncoding = preferHuffmanEncoding
        self.datagramBuffer = HTTP3DatagramBuffer(maxAllowedSize: maxBufferedDatagramBytes)
    }

    func setConnectionHandler(_ handler: HTTP3ConnectionHandler<QUICStreamCreator>?) {
        self.eventLoop.preconditionInEventLoop()
        self.connection = handler
    }

    func initialize() {
        self.eventLoop.preconditionInEventLoop()
        // Initialize the connection state machine, then make whichever outbound streams it tells us to make
        let action = self.connectionStateMachine.initialize()
        switch action {
        case .createControlAndDecoderStreams:
            self.createControlStream()
            self.createQPACKDecoderInstructionStream()
        case .createControlStream:
            self.createControlStream()
        case .none:
            break
        }
    }

    // MARK: Datagram

    enum ReceivedDatagramAction {
        /// Deliver the datagram to the connection channel.
        case deliver
        /// Don't deliver the datagram: it was either buffered or dropped.
        case drop
        /// Close the connection with the given error.
        case closeConnection(HTTP3Error)
    }

    /// Returns what the connection should do with the given datagram.
    ///
    /// Datagrams may be buffered if the stream isn't open yet or dropped if the connection
    /// isn't in a state to receive datagrams.
    func receivedDatagram(_ datagram: HTTP3Datagram) -> ReceivedDatagramAction {
        self.eventLoop.assertInEventLoop()

        switch self.connectionStateMachine.receivedDatagram(streamID: datagram.streamID) {
        case .forward:
            return .deliver
        case .buffer:
            self.datagramBuffer.append(datagram)
            return .drop
        case .discard:
            return .drop
        case .connectionError(let error):
            return .closeConnection(error)
        }
    }

    /// Whether a datagram associated with the given stream may be sent to the remote.
    func sendDatagram(streamID: QUICStreamID) -> HTTP3ConnectionStateMachine.SendDatagramAction {
        self.eventLoop.assertInEventLoop()
        return self.connectionStateMachine.sendDatagram(streamID: streamID)
    }

    /// Delivers any datagrams which were buffered for the given stream.
    ///
    /// Must only be called once the state machine knows the stream is open, i.e. once it will stop
    /// buffering datagrams for it, otherwise datagrams can be delivered out of order.
    private func emitBufferedDatagrams(forStream streamID: QUICStreamID) {
        self.eventLoop.assertInEventLoop()
        assert(self.connectionStateMachine.isStreamOpen(streamID))
        assert(self.connection != nil)
        if let datagrams = self.datagramBuffer.unbufferDatagrams(forStream: streamID) {
            self.connection?.emitDatagrams(datagrams)
        }
    }

    // MARK: Outbound streams

    /// Create an outbound stream, write the stream type, add the handlers and tell the state machine that it's ready.
    private func createQPACKEncoderInstructionStream() {
        self.eventLoop.assertInEventLoop()
        let preferHuffmanEncoding = self.preferHuffmanEncoding
        self.createOutboundUnidirectionalStream(ofType: .qpackEncoder) {
            let streamChannel = $0.channel
            let streamID = $0.streamID
            return streamChannel.eventLoop.makeCompletedFuture {
                let codingHandler = MessageToByteHandler(
                    QPACKEncoderInstructionEncoder(preferHuffmanEncoding: preferHuffmanEncoding)
                )
                try streamChannel.pipeline.syncOperations.addHandlers(
                    codingHandler,
                    self.outboundQPACKEncoderHandler
                )
                try self.addStreamClosedHandler(
                    streamChannel: streamChannel,
                    streamID: streamID,
                    streamType: .unidirectional(.qpackEncoder)
                )
                return streamID
            }
        }.assumeIsolated().whenComplete {
            switch $0 {
            case .success(let streamID):
                self.logger.trace(
                    "Opened outbound QPACK encoder stream",
                    metadata: [LoggingKeys.quicStreamID: "\(streamID)"]
                )
                let action = self.connectionStateMachine.outboundEncoderStreamReady(streamID: streamID)
                switch action {
                case .sendEncoderInstruction(let instruction):
                    self.outboundQPACKEncoderHandler.sendInstruction(instruction)
                case .none:
                    break
                }
            case .failure(let error):
                self.logger.error(
                    "Failed to create QPACK encoder stream",
                    metadata: [LoggingKeys.error: "\(error)"]
                )
            }
        }
    }

    /// Create an outbound stream, write the stream type and add the handlers.
    private func createQPACKDecoderInstructionStream() {
        self.eventLoop.assertInEventLoop()
        self.createOutboundUnidirectionalStream(ofType: .qpackDecoder) {
            let streamChannel = $0.channel
            let streamID = $0.streamID
            return streamChannel.eventLoop.makeCompletedFuture {
                let codingHandler = MessageToByteHandler(QPACKDecoderInstructionEncoder())
                try streamChannel.pipeline.syncOperations.addHandlers(
                    codingHandler,
                    self.outboundQPACKDecoderHandler
                )
                try self.addStreamClosedHandler(
                    streamChannel: streamChannel,
                    streamID: streamID,
                    streamType: .unidirectional(.qpackDecoder)
                )
                return streamID
            }
        }.assumeIsolated().whenComplete {
            switch $0 {
            case .success(let streamID):
                self.logger.trace(
                    "Opened outbound QPACK decoder stream",
                    metadata: [LoggingKeys.quicStreamID: "\(streamID)"]
                )
                let action = self.connectionStateMachine.outboundDecoderStreamReady(streamID: streamID)
                switch action {
                case .sendDecoderInstructions(let instructions):
                    self.outboundQPACKDecoderHandler.sendInstructions(instructions)
                case .none:
                    break
                }
            case .failure(let error):
                self.logger.error(
                    "Failed to create QPACK decoder stream",
                    metadata: [LoggingKeys.error: "\(error)"]
                )
            }
        }
    }

    /// Create an outbound stream, write the stream type, add the handlers. The handler will write the initial settings.
    private func createControlStream() {
        self.eventLoop.assertInEventLoop()
        self.createOutboundUnidirectionalStream(ofType: .control) {
            let streamChannel = $0.channel
            let streamID = $0.streamID
            return streamChannel.eventLoop.assumeIsolated().makeCompletedFuture {
                self.connectionStateMachine.outboundControlStreamReady(streamID: streamID)
                try self.addHTTP3FrameHandlers(
                    streamChannel: streamChannel,
                    streamID: streamID,
                    streamType: .control,
                    incoming: false
                )
                try streamChannel.pipeline.syncOperations.addHandler(self.outboundControlStreamHandler)
                return streamID
            }
        }.assumeIsolated().whenComplete {
            switch $0 {
            case .success(let streamID):
                self.logger.trace("Opened outbound control stream", metadata: [LoggingKeys.quicStreamID: "\(streamID)"])
            case .failure(let error):
                self.logger.error("Failed to open outbound control stream", metadata: [LoggingKeys.error: "\(error)"])
            }
        }
    }

    @discardableResult
    func createOutboundUnidirectionalStream<T: Sendable>(
        ofType type: HTTP3StreamType.Unidirectional,
        initializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        self.eventLoop.preconditionInEventLoop()
        let logger = self.logger
        return self.streamCreator.assumeIsolated().createUnidirectionalStream {
            logger.debug(
                "Creating outbound stream",
                metadata: [LoggingKeys.quicStreamID: "\($0.streamID)", LoggingKeys.h3StreamType: "\(type)"]
            )
            $0.channel.writeStreamType(type)
            return initializer(HTTP3StreamInitializerParameters($0))
        }
    }

    func createOutboundRequestStream<InitializerOutput: Sendable>(
        addTypeHandlers: Bool,
        streamInitializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<InitializerOutput>
    ) -> EventLoopFuture<InitializerOutput> {
        self.eventLoop.preconditionInEventLoop()
        let action = self.connectionStateMachine.outboundRequestStreamRequested()
        switch action {
        case .create:
            return self.streamCreator.assumeIsolated().createBidirectionalStream { params in
                let streamChannel = params.channel
                let streamID = params.streamID
                return streamChannel.eventLoop.makeCompletedFuture {
                    self.connectionStateMachine.outboundRequestStreamReady(streamID: streamID)
                    try self.addHTTP3FrameHandlers(
                        streamChannel: streamChannel,
                        streamID: streamID,
                        streamType: .request,
                        incoming: false
                    )
                    if addTypeHandlers {
                        try streamChannel.pipeline.syncOperations.addHandler(HTTP3ToHTTPClientCodec())
                    }
                    self.emitBufferedDatagrams(forStream: streamID)
                    return HTTP3StreamInitializerParameters(params)
                }.assumeIsolated().flatMap {
                    streamInitializer($0)
                }.nonisolated()
            }
        case .failedToCreateStream(let error):
            return self.eventLoop.makeFailedFuture(error)
        }
    }

    // MARK: - New Inbound streams -

    func inboundStreamInitializer<Output: Sendable>(
        parameters: HTTP3StreamInitializerParameters,
        addTypeHandlers: Bool,
        userInboundStreamInitializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Output>,
        internalInboundStreamInitializer: (
            (
                any Channel, QUICStreamID, HTTP3StreamType.Unidirectional
            ) -> EventLoopFuture<Void>
        )?,
        onUserStream: @escaping @Sendable (Output) -> Void
    ) -> EventLoopFuture<Void> {
        self.eventLoop.preconditionInEventLoop()
        if parameters.streamID.isBidirectional {
            // A bidirectional stream must be a request stream
            // Add the h3 handlers which will en/decode the h3 frames
            return self.inboundRequestStreamInitializer(
                parameters: parameters,
                addTypeHandlers: addTypeHandlers,
                userInboundStreamInitializer: userInboundStreamInitializer,
                onUserStream: onUserStream
            )
        } else {
            return self.inboundUnidirectionalStreamInitializer(
                parameters: parameters,
                internalInboundStreamInitializer: internalInboundStreamInitializer
            )
        }
    }

    private func inboundRequestStreamInitializer<Output: Sendable>(
        parameters: HTTP3StreamInitializerParameters,
        addTypeHandlers: Bool,
        userInboundStreamInitializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Output>,
        onUserStream: @escaping @Sendable (Output) -> Void
    ) -> EventLoopFuture<Void> {
        let streamID = parameters.streamID
        let streamChannel = parameters.channel
        let action = self.connectionStateMachine.inboundRequestStreamReceived(streamID: streamID)
        switch action {
        case .addHandlers:
            do {
                try self.addHTTP3FrameHandlers(
                    streamChannel: streamChannel,
                    streamID: streamID,
                    streamType: .request,
                    incoming: true
                )
                if addTypeHandlers {
                    try streamChannel.pipeline.syncOperations.addHandler(HTTP3ToHTTPServerCodec())
                }
                // State machine now considers the stream to be open: deliver the datagrams now.
                self.emitBufferedDatagrams(forStream: streamID)
                return userInboundStreamInitializer(parameters).map(onUserStream)
            } catch {
                self.datagramBuffer.discardDatagrams(forStream: streamID)
                return streamChannel.eventLoop.makeFailedFuture(error)
            }
        case .emitConnectionError(let error):
            self.datagramBuffer.discardDatagrams(forStream: streamID)
            return streamChannel.eventLoop.makeCompletedFuture {
                try self.addStreamClosedHandler(
                    streamChannel: streamChannel,
                    streamID: streamID,
                    streamType: .request
                )
                self.connection?.emitConnectionError(error)
            }
        case .emitStreamError:
            self.logger.trace("Rejecting inbound stream", metadata: [LoggingKeys.quicStreamID: "\(streamID)"])
            self.datagramBuffer.discardDatagrams(forStream: streamID)
            return streamChannel.eventLoop.makeCompletedFuture {
                try self.addStreamClosedHandler(
                    streamChannel: streamChannel,
                    streamID: streamID,
                    streamType: .request
                )
                streamChannel.triggerUserOutboundEvent(
                    QUICStopSendingEvent(code: QUICApplicationErrorCode(.requestRejected)),
                    promise: nil
                )
            }
        }
    }

    private func inboundUnidirectionalStreamInitializer(
        parameters: HTTP3StreamInitializerParameters,
        internalInboundStreamInitializer: (
            (
                any Channel, QUICStreamID, HTTP3StreamType.Unidirectional
            ) -> EventLoopFuture<Void>
        )?,
    ) -> EventLoopFuture<Void> {
        let streamID = parameters.streamID
        let streamChannel = parameters.channel

        // An inbound unidirectional stream should send us its type in the stream header
        // We add a handler which will read that first byte to know the type
        // Then, it will call the provided callback and there we can add more handlers accordingly
        let typeDecoderHandler = HTTP3UnidirectionalStreamTypeDecoderHandler(logger: logger) { streamType in
            self.logger.trace(
                "Received a new inbound stream",
                metadata: [
                    LoggingKeys.quicStreamID: "\(streamID)", LoggingKeys.h3StreamType: "\(streamType.rawValue)",
                ]
            )
            return streamChannel.eventLoop.makeCompletedFuture {
                switch streamType {
                case .push:
                    try self.handleInboundPushStream(streamChannel, streamID: streamID)
                case .unknown:
                    try self.handleInboundUnknownStream(streamChannel, streamID: streamID, streamType: streamType)
                case .control:
                    try self.handleInboundControlStream(streamChannel, streamID: streamID)
                case .qpackEncoder:
                    try self.handleInboundQPACKEncoderStream(streamChannel, streamID: streamID)
                case .qpackDecoder:
                    try self.handleInboundQPACKDecoderStream(streamChannel, streamID: streamID)
                }
            }.assumeIsolated().flatMap { _ in
                if let int = internalInboundStreamInitializer {
                    return int(streamChannel, streamID, streamType).map { _ in .ready }
                }
                return streamChannel.eventLoop.makeSucceededFuture(.ready)
            }.nonisolated()
        }
        return streamChannel.eventLoop.assumeIsolated().makeCompletedFuture {
            try streamChannel.pipeline.syncOperations.addHandler(typeDecoderHandler)
        }
    }

    private func handleInboundPushStream(
        _ streamChannel: any Channel,
        streamID: QUICStreamID,
    ) throws {
        let action = self.connectionStateMachine.inboundPushStreamReceived(streamID: streamID)
        switch action {
        case .emitConnectionError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.push)
            )
            self.connection?.emitConnectionError(error)
        case .emitStreamError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.push)
            )
            throw error
        }
    }

    private func handleInboundUnknownStream(
        _ streamChannel: any Channel,
        streamID: QUICStreamID,
        streamType: HTTP3StreamType.Unidirectional
    ) throws {
        let action = self.connectionStateMachine.inboundUnknownStreamReceived(
            streamID: streamID,
            streamType: streamType
        )
        switch action {
        case .emitStreamError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(streamType)
            )
            throw error
        }

    }

    private func handleInboundControlStream(
        _ streamChannel: any Channel,
        streamID: QUICStreamID,
    ) throws {
        let action = self.connectionStateMachine.inboundControlStreamReceived(streamID: streamID)
        switch action {
        case .addHandlers:
            // Control streams carry h3 frames
            try self.addHTTP3FrameHandlers(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .control,
                incoming: true
            )

            // This is internal. Don't add the users handlers. Instead, add the control stream handler
            let internalHandler = HTTP3InboundControlStreamHandler(
                coordinator: self,
                streamID: streamID
            )
            try streamChannel.pipeline.syncOperations.addHandler(internalHandler)
        case .emitConnectionError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.control)
            )
            self.connection?.emitConnectionError(error)
        case .emitStreamError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.control)
            )
            throw error
        }
    }

    private func handleInboundQPACKEncoderStream(
        _ streamChannel: any Channel,
        streamID: QUICStreamID,
    ) throws {
        let action = self.connectionStateMachine.inboundQPACKEncoderStreamReceived(streamID: streamID)
        switch action {
        case .addHandlers:
            // qpack streams do not carry h3 frames
            let decoder = ByteToMessageHandler(QPACKEncoderInstructionDecoder())
            let forwarder = QPACKInboundEncoderStreamHandler { instruction in
                let action = self.connectionStateMachine.receivedIncomingEncoderInstruction(instruction)
                switch action {
                case .emitConnectionError(let error):
                    self.connection?.emitConnectionError(error)
                case .sendDecoderInstruction(let instruction):
                    self.outboundQPACKDecoderHandler.sendInstruction(instruction)
                    self.checkForNewDecodes()
                case .none:
                    break
                }
            } onError: { error in
                self.emitConnectionErrorFromStream(
                    HTTP3Error(
                        code: .qpackEncoderStreamError,
                        message: "Invalid QPACK instruction",
                        cause: error,
                        errorCode: .qpackEncoderStreamError,
                        location: .here()
                    )
                )
            }
            try streamChannel.pipeline.syncOperations.addHandler(decoder)
            try streamChannel.pipeline.syncOperations.addHandler(forwarder)
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.qpackEncoder)
            )
        case .emitConnectionError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.qpackEncoder)
            )
            self.connection?.emitConnectionError(error)
        case .emitStreamError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.control)
            )
            throw error
        }
    }

    private func handleInboundQPACKDecoderStream(
        _ streamChannel: any Channel,
        streamID: QUICStreamID,
    ) throws {
        let action = self.connectionStateMachine.inboundQPACKDecoderStreamReceived(streamID: streamID)
        switch action {
        case .addHandlers:
            // qpack streams do not carry h3 frames
            let decoder = ByteToMessageHandler(QPACKDecoderInstructionDecoder())
            let forwarder = QPACKInboundDecoderStreamHandler {
                let action = self.connectionStateMachine.receivedIncomingDecoderInstruction($0)
                switch action {
                case .emitConnectionError(let error):
                    self.connection?.emitConnectionError(error)
                case .none:
                    break
                }
            } onError: { error in
                self.emitConnectionErrorFromStream(
                    HTTP3Error(
                        code: .qpackEncoderStreamError,
                        message: "Invalid QPACK instruction",
                        cause: error,
                        errorCode: .qpackEncoderStreamError,
                        location: .here()
                    )
                )
            }
            try streamChannel.pipeline.syncOperations.addHandler(decoder)
            try streamChannel.pipeline.syncOperations.addHandler(forwarder)
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.qpackDecoder)
            )
        case .emitConnectionError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.qpackDecoder)
            )
            self.connection?.emitConnectionError(error)
        case .emitStreamError(let error):
            try self.addStreamClosedHandler(
                streamChannel: streamChannel,
                streamID: streamID,
                streamType: .unidirectional(.qpackDecoder)
            )
            throw error
        }
    }

    // MARK: Inbound frames

    /// Handler must call this every time we receive an incoming frame on the control stream.
    func receivedControlFrame(_ frame: HTTP3Frame, streamID: QUICStreamID) {
        self.eventLoop.preconditionInEventLoop()
        self.logger.trace(
            "Received control frame",
            metadata: [LoggingKeys.h3Frame: "\(frame)", LoggingKeys.quicStreamID: "\(streamID)"]
        )

        let action = self.connectionStateMachine.receivedControlFrame(frame)
        switch action {
        case .none:
            break
        case .emitConnectionError(let error):
            self.connection?.emitConnectionError(error)
        case .onSettings(let onSettings):
            if onSettings.makeEncoderInstructionStream {
                self.createQPACKEncoderInstructionStream()
            }
            self.connection?.fireReceivedSettingsEvent(
                ReceivedSettings(datagramsSupported: onSettings.datagramsNegotiated)
            )
        case .cancelStreams(let ids):
            self.cancelStreamsDueToReceivingGoaway(ids)
        case .closeConnection:
            self.logger.trace("GOAWAY with stream id \(streamID) resulting in immediate connection closure")
            self.shutdownConnectionImmediately()
        }
    }

    // MARK: Handlers

    /// Add a handler which waits for close then informs the state machine that the stream was closed.
    /// This should not be added to streams which already have a HTTP3StreamHandler.
    /// This is for QPACK streams and unknown streams, or rejected streams (because rejected streams don't get the HTTP3StreamHandler).
    /// It is critical because we keep state of all open streams, so we need to know when a stream has closed.
    private func addStreamClosedHandler(
        streamChannel: any Channel,
        streamID: QUICStreamID,
        streamType: HTTP3StreamType
    ) throws {
        self.eventLoop.assertInEventLoop()
        streamChannel.eventLoop.assertInEventLoop()
        let handler = StreamClosedHandler {
            self.onStreamClosed(streamID: streamID, seenEOF: true, streamType: streamType)
        }
        try streamChannel.pipeline.syncOperations.addHandler(handler)
    }

    private func addHTTP3FrameHandlers(
        streamChannel: any Channel,
        streamID: QUICStreamID,
        streamType: HTTP3StreamType.Framed,
        incoming: Bool
    ) throws {
        self.eventLoop.assertInEventLoop()
        streamChannel.eventLoop.assertInEventLoop()
        var logger = self.logger
        logger[metadataKey: LoggingKeys.h3StreamType] = "\(streamType)"
        logger[metadataKey: LoggingKeys.quicStreamID] = "\(streamID)"
        let streamHandler = HTTP3StreamHandler(
            stateMachine: .init(
                streamType: streamType,
                incoming: incoming,
                preferHuffmanEncoding: self.preferHuffmanEncoding
            ),
            streamID: streamID,
            streamType: streamType,
            delegate: self,
            logger: logger
        )
        try streamChannel.pipeline.syncOperations.addHandler(streamHandler)
        self.streamHandlers[streamID] = streamHandler
    }

    // MARK: Actions

    func encodeHeaders(_ headers: [HTTPField], forStream streamID: QUICStreamID) -> HTTP3PartialFrame.Headers {
        self.eventLoop.assertInEventLoop()
        let result = self.connectionStateMachine.encodeHeaders(headers, forStream: streamID)
        self.outboundQPACKEncoderHandler.sendInstructions(result.instructions)
        return HTTP3PartialFrame.Headers(fieldSection: result.fieldSection)
    }

    func decodeHeaders(_ headers: HTTP3PartialFrame.Headers, forStream streamID: QUICStreamID) {
        self.eventLoop.assertInEventLoop()
        let action = self.connectionStateMachine.decodeHeaders(headers, forStream: streamID)
        switch action {
        case .informDecodeError(let payload):
            // Safe to unwrap because a handler must have been created for this stream for it to have registered that it wants this result.
            // And that handler cannot have been removed yet because removal only happens when the stream closes.
            // And stream closing would have triggered pending decodes to be dropped, so we wouldn't have reached here.
            self.streamHandlers[payload.streamID]!.onQPACKDecodeError(
                payload.error,
                forHeaders: payload.headers
            )
        case .informDecodeResult(let payload):
            self.processQPACKDecodeResult(payload)
        case .emitConnectionError(let error):
            self.connection?.emitConnectionError(error)
        case .none:
            break
        }
    }

    /// Call this to tell the coordinator that a stream has been closed. Will drop pending QPACK decodes and perform other cleanup.
    /// - Parameters:
    ///   - streamID: The ID of the stream which was closed.
    ///   - seenEOF: True if the stream was closed without potentially dropping incoming frames.
    ///   - streamType: The type of the stream which was closed.
    private func onStreamClosed(streamID: QUICStreamID, seenEOF: Bool, streamType: HTTP3StreamType) {
        self.eventLoop.assertInEventLoop()
        self.logger.trace("Stream has closed", metadata: [LoggingKeys.quicStreamID: "\(streamID)"])
        // It's safe to remove this now. When we tell the state machine about the closure, it'll remove any queued QPACK decodes.
        self.streamHandlers[streamID] = nil
        // Anything buffered will never be delivered, drop them.
        self.datagramBuffer.discardDatagrams(forStream: streamID)
        let action = self.connectionStateMachine.streamClosed(
            streamID: streamID,
            seenEOF: seenEOF,
            streamType: streamType
        )
        switch action {
        case .sendDecoderInstruction(let instruction, let shouldCloseConnection):
            self.outboundQPACKDecoderHandler.sendInstruction(instruction)
            if shouldCloseConnection {
                self.logger.trace(
                    "Shutting connection because we previously got a GOAWAY, and there are now no more streams open"
                )
                self.shutdownConnectionImmediately()
            }
        case .closeConnection:
            self.logger.trace(
                "Shutting connection because we previously got a GOAWAY, and there are now no more streams open"
            )
            self.shutdownConnectionImmediately()
        case .emitConnectionError(let error):
            self.connection?.emitConnectionError(error)
        case .none:
            break
        }
    }

    /// Immediately close down the connection and emit NO\_ERROR as the reason.
    func shutdownConnectionImmediately() {
        self.eventLoop.preconditionInEventLoop()
        self.logger.trace("Immediately closing connection")
        let action = self.connectionStateMachine.shutdownConnectionImmediately()
        switch action {
        case .shutdown:
            self.connection?.emitConnectionError(
                .init(
                    code: .none,
                    message: "",
                    cause: nil,
                    errorCode: .noError,
                    location: .here()
                )
            )
        }
    }

    /// Check if the qpack state has new decodes available for us
    private func checkForNewDecodes() {
        self.eventLoop.assertInEventLoop()
        while let action = self.connectionStateMachine.checkPendingQPACKDecodes() {
            switch action {
            case .informDecodeError(let payload):
                // Safe to unwrap because a handler must have been created for this stream for it to have registered that it wants this result.
                // And that handler cannot have been removed yet because removal only happens when the stream closes.
                // And stream closing would have triggered pending decodes to be dropped, so we wouldn't have reached here.
                self.streamHandlers[payload.streamID]!.onQPACKDecodeError(
                    payload.error,
                    forHeaders: payload.headers
                )
            case .informDecodeResult(let payload):
                self.processQPACKDecodeResult(payload)
            case .emitConnectionError(let error):
                self.connection?.emitConnectionError(error)
            }
        }
    }

    private func processQPACKDecodeResult(_ result: HTTP3ConnectionStateMachine.DecodeHeaderAction.InformDecodeResult) {
        self.eventLoop.assertInEventLoop()
        // Safe to unwrap because a handler must have been created for this stream for it to have registered that it wants this result.
        // And that handler cannot have been removed yet because removal only happens when the stream closes.
        // And stream closing would have triggered pending decodes to be dropped, so we wouldn't have reached here.
        self.streamHandlers[result.streamID]!.onQPACKDecodeResult(
            fields: result.fields,
            forHeaders: result.headers
        )
        if let i = result.instructionToWrite {
            self.outboundQPACKDecoderHandler.sendInstruction(i)
        }
    }

    // MARK: Closing

    /// Tell the indicated streams that they have been cancelled due to a GOAWAY being sent.
    private func cancelStreamsDueToSendingGoaway(_ ids: [QUICStreamID]) {
        self.eventLoop.assertInEventLoop()
        // Tell each handler that we got cancelled
        for id in ids {
            guard let handler = self.streamHandlers[id] else {
                assertionFailure("Stream \(id) cancelled but we didn't have a handler")
                continue
            }
            handler.cancelStreamDueToSendingGoaway()
        }
    }

    /// Tell the indicated streams that they have been cancelled due to a GOAWAY being received.
    private func cancelStreamsDueToReceivingGoaway(_ ids: [QUICStreamID]) {
        self.eventLoop.assertInEventLoop()
        // Tell each handler that we got cancelled
        for id in ids {
            guard let handler = self.streamHandlers[id] else {
                assertionFailure("Stream \(id) cancelled but we didn't have a handler")
                continue
            }
            handler.cancelStreamDueToReceivedGoaway()
        }
    }

    /// Tell the indicated streams that they have been cancelled due to the connection being closed.
    private func cancelStreamsDueToConnectionClose(_ ids: [QUICStreamID]) {
        self.eventLoop.assertInEventLoop()
        for id in ids {
            guard let handler = self.streamHandlers[id] else {
                assertionFailure("Stream \(id) cancelled but we didn't have a handler")
                continue
            }
            handler.cancelStreamDueToConnectionClose()
        }
    }

    /// Whether a graceful shutdown can be initiated by this endpoint.
    ///
    /// Returns `false` if the connection is not yet open or has already finished, or if a graceful shutdown has already
    /// been initiated.
    func canInitiateGracefulShutdown() -> Bool {
        self.connectionStateMachine.canInitiateGracefulShutdown()
    }

    /// Send a GOAWAY to the remote and begin shutting down the connection.
    ///
    /// - Throws: If the given ID is not valid, for example it is higher than a previously given ID.
    func sendGoaway(goawayID: HTTP3GoawayID) throws {
        self.eventLoop.preconditionInEventLoop()
        let action = self.connectionStateMachine.sendGoaway(goawayID: goawayID)
        switch action {
        case .closeImmediately:
            // We will only reach here if the connection state machine is in the `.notStarted` case; the state machine
            // can only be in the `.notStarted` case if `channelActive` has not been called.
            self.shutdownConnectionImmediately()
        case .sendGoaway(let id, let streamsToCancel, let lowestRejectedStreamID):
            self.logger.trace("Sending goaway", metadata: [LoggingKeys.goawayID: "\(id)"])
            self.outboundControlStreamHandler.sendGoaway(id: id)
            self.cancelStreamsDueToSendingGoaway(streamsToCancel)
            if let lowestRejectedStreamID {
                // These streams will never be opened: drop any datagrams for them.
                self.datagramBuffer.discardDatagrams(forStreamsAtOrAbove: lowestRejectedStreamID)
            }
        case .throwError(let error):
            throw error
        case .none:
            break
        }
    }

    /// Returns the next expected client-initiated bidirectional stream ID, or `nil` if the connection is not in the
    /// `HTTP3ConnectionStateMachine/State/initialized` state.
    func nextExpectedClientInitiatedBidirectionalStreamID() -> QUICStreamID? {
        self.connectionStateMachine.nextExpectedClientInitiatedBidirectionalStreamID()
    }

    /// Asserts that there are currently no streams open according to the connection state.
    func assertNoOpenStreams() {
        self.connectionStateMachine.assertNoOpenStreams(logger: self.logger)
    }

    /// Call this when a stream wants to emit a connection-level error.
    func emitConnectionErrorFromStream(_ error: HTTP3Error) {
        self.logger.debug("Emitting connection error", metadata: [LoggingKeys.error: "\(error)"])
        let action = self.connectionStateMachine.emitConnectionErrorFromStream(error: error)
        switch action {
        case .emitConnectionError(let error):
            self.connection?.emitConnectionError(error)
        case .none:
            assertionFailure("Tried to emit stream error when already finished.")
        }
    }

    /// Call this when the remote sends a datagram which can't be accepted, i.e. it can't be parsed
    /// or wasn't negotiated.
    func receivedInvalidDatagram(_ error: HTTP3Error) {
        self.eventLoop.assertInEventLoop()
        self.logger.debug("Emitting connection error", metadata: [LoggingKeys.error: "\(error)"])
        switch self.connectionStateMachine.emitConnectionErrorFromStream(error: error, allowNotStarted: true) {
        case .emitConnectionError(let error):
            self.connection?.emitConnectionError(error)
        case .none:
            ()  // Already closed, nothing to do.
        }
    }

    /// Call this when we catch an error coming in from the remote
    func caughtRemoteError(_ error: HTTP3Error) {
        let action = self.connectionStateMachine.caughtRemoteError(error)
        switch action {
        case .cancelStreams(let ids):
            self.cancelStreamsDueToConnectionClose(ids)
        case nil:
            break
        }
    }
}

@available(*, unavailable)
extension HTTP3ConnectionCoordinator: Sendable {}

extension Channel {
    fileprivate func writeStreamType(_ streamType: HTTP3StreamType.Unidirectional) {
        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(streamType.rawValue, strategy: .quic)
        self.writeAndFlush(buffer, promise: nil)
    }
}

extension HTTP3ConnectionCoordinator: HTTP3StreamDelegate {
    func onStreamClosed(_ sawEOF: Bool, streamID: NIOQUICHelpers.QUICStreamID, streamType: HTTP3.HTTP3StreamType.Framed)
    {
        self.onStreamClosed(streamID: streamID, seenEOF: sawEOF, streamType: .init(streamType))
    }

    func onConnectionError(_ error: HTTP3.HTTP3Error) {
        self.emitConnectionErrorFromStream(error)
    }

}
