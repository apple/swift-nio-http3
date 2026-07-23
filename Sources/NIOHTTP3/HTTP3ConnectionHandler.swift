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

public import HTTP3
public import Logging
public import NIOCore
public import NIOQUICHelpers

/// What to do when a new stream comes inbound.
package enum H3InboundStreamInitializer {
    /// Call yield on a multiplexer to give it the new stream channel.
    case multiplexer(any StreamMultiplexerContinuation)
    /// Call a closure with the new stream channel.
    case closure((HTTP3StreamInitializerParameters) -> EventLoopFuture<Void>)
}

/// This is the main handler to be used in HTTP/3 servers and clients.
///
/// This handler should be in a QUIC connection channel pipeline, and thus there should be one instance of this handler per connection.
/// It expects to be told about any incoming stream channels by calling ``HTTP3ConnectionHandler/inboundStreamReceived(_:)``.
/// The handler is also able to make outbound streams, see ``HTTP3ConnectionHandler/createRequestStream(streamInitializer:)``.
public final class HTTP3ConnectionHandler<StreamCreator: QUICStreamCreator & SendableMetatype>:
    ChannelInboundHandler,
    ChannelOutboundHandler
{
    public typealias InboundIn = Any
    public typealias OutboundIn = Any

    private let addTypeHandlers: Bool
    private let coordinator: HTTP3ConnectionCoordinator<StreamCreator>
    private let logger: Logger
    private let inboundStreamInitializer: H3InboundStreamInitializer
    private let internalInboundStreamInitializer:
        ((any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>)?

    /// A closure that returns the current QUIC round-trip time estimate. Used to compute the time to wait between
    /// sending the first and second GOAWAY frames during graceful shutdown.
    private let rttProvider: (@Sendable () -> TimeAmount)

    /// The multiplier applied to the RTT when computing the time the server should wait between sending the first and
    /// second GOAWAY frames during graceful shutdown.
    private let gracefulShutdownRTTMultiplier: Int
    /// Whether we are the server or the client.
    private let type: HTTP3ConnectionType

    private var context: ChannelHandlerContext?

    /// Create a new HTTP3ConnectionHandler.
    private init(
        eventLoop: any EventLoop,
        addTypeHandlers: Bool,
        settings: HTTP3Settings,
        streamCreator: StreamCreator,
        type: HTTP3ConnectionType,
        preferHuffmanEncoding: Bool,
        logger: Logger,
        inboundStreamInitializer: H3InboundStreamInitializer,
        internalInboundStreamInitializer: (
            (
                any Channel, QUICStreamID, HTTP3StreamType.Unidirectional
            ) -> EventLoopFuture<Void>
        )?,
        rttProvider: @escaping (@Sendable () -> TimeAmount),
        gracefulShutdownRTTMultiplier: Int
    ) {
        if settings.qpackMaximumTableCapacity > 0 {
            // These settings would enable the peer to use the dynamic table
            // We must not allow that, see the DynamicTable doc for explanation.
            fatalError("Dynamic table is not supported yet")
        }
        self.addTypeHandlers = addTypeHandlers
        self.logger = logger
        self.coordinator = HTTP3ConnectionCoordinator(
            eventLoop: eventLoop,
            localSettings: settings,
            streamCreator: streamCreator,
            type: type,
            preferHuffmanEncoding: preferHuffmanEncoding,
            logger: logger
        )
        self.type = type
        self.rttProvider = rttProvider
        self.gracefulShutdownRTTMultiplier = gracefulShutdownRTTMultiplier
        self.inboundStreamInitializer = inboundStreamInitializer
        self.internalInboundStreamInitializer = internalInboundStreamInitializer

        self.coordinator.emitConnectionError = { error in
            self.logger.debug(
                "Closing connection",
                metadata: [
                    LoggingKeys.error: "\(error.h3ErrorCode ?? .noError)", LoggingKeys.reason: "\(error.message)",
                ]
            )
            self.context?.triggerUserOutboundEvent(
                QUICCloseConnectionEvent(
                    code: QUICApplicationErrorCode(error.h3ErrorCode ?? .noError),
                    reasonPhrase: error.message
                ),
                promise: nil
            )
        }
    }

    /// Create a ``HTTP3ConnectionHandler`` for use in a server.
    /// - Parameters:
    ///   - eventLoop: The event loop of the channel this handler will be on.
    ///   - configuration: Configuration for the handler.
    ///   - settings: The HTTP3Settings to be used on each incoming connection.
    ///   - streamCreator: For creating outbound streams.
    ///   - logger: A logger.
    ///   - inboundRequestStreamInitializer: A closure which will be called for every incoming request stream.
    /// - Returns: A ``HTTP3ConnectionHandler``.
    public static func server(
        eventLoop: any EventLoop,
        configuration: HTTP3ServerConfiguration,
        settings: HTTP3Settings,
        streamCreator: StreamCreator,
        logger: Logger,
        inboundRequestStreamInitializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Void>
    ) -> Self {
        self.server(
            eventLoop: eventLoop,
            configuration: configuration,
            settings: settings,
            streamCreator: streamCreator,
            logger: logger,
            inboundRequestStreamInitializer: .closure(inboundRequestStreamInitializer),
            internalInboundStreamInitializer: nil
        )
    }

    /// Internal version of the above, allows accessing internal inbound streams.
    /// - Parameters:
    ///   - eventLoop: The event loop of the channel this handler will be on.
    ///   - configuration: Configuration for the handler.
    ///   - settings: The HTTP3Settings to be used on each incoming connection.
    ///   - streamCreator: For creating outbound streams.
    ///   - logger: A logger.
    ///   - inboundRequestStreamInitializer: A closure which will be called for every incoming request stream.
    ///   - internalInboundStreamInitializer: A closure which will be called for every incoming non-request stream.
    /// - Returns: A ``HTTP3ConnectionHandler``.
    package static func server(
        eventLoop: any EventLoop,
        configuration: HTTP3ServerConfiguration,
        settings: HTTP3Settings,
        streamCreator: StreamCreator,
        logger: Logger,
        inboundRequestStreamInitializer:
            @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<
                Void
            >,
        internalInboundStreamInitializer: (
            (any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>
        )?
    ) -> Self {
        self.server(
            eventLoop: eventLoop,
            configuration: configuration,
            settings: settings,
            streamCreator: streamCreator,
            logger: logger,
            inboundRequestStreamInitializer: .closure(inboundRequestStreamInitializer),
            internalInboundStreamInitializer: internalInboundStreamInitializer
        )
    }

    /// Create a ``HTTP3ConnectionHandler`` for use in a server.
    /// - Parameters:
    ///   - eventLoop: The event loop of the channel this handler will be on.
    ///   - configuration: Configuration for the handler.
    ///   - settings: The HTTP3Settings to be used on each incoming connection.
    ///   - streamCreator: For creating outbound streams.
    ///   - logger: A logger.
    ///   - connection: An instance of ``HTTP3ServerConnection`` which inbound connections can be vended to.
    /// - Returns: A ``HTTP3ConnectionHandler``.
    @_spi(HTTP3AsyncInterface)
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public static func server<Output: Sendable>(
        eventLoop: any EventLoop,
        configuration: HTTP3ServerConfiguration,
        settings: HTTP3Settings,
        streamCreator: StreamCreator,
        logger: Logger,
        connection: HTTP3ServerConnection<Output, StreamCreator>
    ) -> Self {
        self.server(
            eventLoop: eventLoop,
            configuration: configuration,
            settings: settings,
            streamCreator: streamCreator,
            logger: logger,
            inboundRequestStreamInitializer: .multiplexer(connection),
            internalInboundStreamInitializer: nil
        )
    }

    private static func server(
        eventLoop: any EventLoop,
        configuration: HTTP3ServerConfiguration,
        settings: HTTP3Settings,
        streamCreator: StreamCreator,
        logger: Logger,
        inboundRequestStreamInitializer: H3InboundStreamInitializer,
        internalInboundStreamInitializer: (
            (any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>
        )?
    ) -> Self {
        Self(
            eventLoop: eventLoop,
            addTypeHandlers: !configuration.emitFrames,
            settings: settings,
            streamCreator: streamCreator,
            type: .server,
            preferHuffmanEncoding: configuration.preferHuffmanEncoding,
            logger: logger,
            inboundStreamInitializer: inboundRequestStreamInitializer,
            internalInboundStreamInitializer: internalInboundStreamInitializer,
            rttProvider: configuration.rttProvider,
            gracefulShutdownRTTMultiplier: configuration.gracefulShutdownRTTMultiplier,
        )
    }

    /// Create a ``HTTP3ConnectionHandler`` for use in a client.
    /// - Parameters:
    ///   - eventLoop: The event loop of the channel this handler will be on.
    ///   - configuration: Configuration for the handler.
    ///   - settings: The HTTP3Settings to be used on each incoming connection.
    ///   - streamCreator: For creating outbound streams.
    ///   - logger: A logger.
    ///   - inboundPushStreamInitializer: A closure which will be called for every incoming push stream.
    /// - Returns: A ``HTTP3ConnectionHandler``.
    public static func client(
        eventLoop: any EventLoop,
        configuration: HTTP3ClientConfiguration,
        settings: HTTP3Settings,
        streamCreator: StreamCreator,
        logger: Logger,
        inboundPushStreamInitializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Void>
    ) -> Self {
        Self(
            eventLoop: eventLoop,
            addTypeHandlers: !configuration.emitFrames,
            settings: settings,
            streamCreator: streamCreator,
            type: .client,
            preferHuffmanEncoding: configuration.preferHuffmanEncoding,
            logger: logger,
            inboundStreamInitializer: .closure(inboundPushStreamInitializer),
            internalInboundStreamInitializer: nil,
            // The `rttProvider` closure and `gracefulShutdownRTTMultiplier` is not used for clients, only servers use
            // it. We only pass values here because the initializer requires it.
            rttProvider: { .milliseconds(100) },
            gracefulShutdownRTTMultiplier: 1
        )
    }

    /// Internal version of the above, allows accessing internal inbound streams.
    /// - Parameters:
    ///   - eventLoop: The event loop of the channel this handler will be on.
    ///   - configuration: Configuration for the handler.
    ///   - settings: The HTTP3Settings to be used on each incoming connection.
    ///   - streamCreator: For creating outbound streams.
    ///   - logger: A logger.
    ///   - inboundPushStreamInitializer: A closure which will be called for every incoming push stream.
    ///   - internalInboundStreamInitializer: A closure which will be called for every incoming non-push stream.
    /// - Returns: A ``HTTP3ConnectionHandler``.
    package static func client(
        eventLoop: any EventLoop,
        configuration: HTTP3ClientConfiguration,
        settings: HTTP3Settings,
        streamCreator: StreamCreator,
        logger: Logger,
        inboundPushStreamInitializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Void>,
        internalInboundStreamInitializer: (
            (any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>
        )?
    ) -> Self {
        Self(
            eventLoop: eventLoop,
            addTypeHandlers: !configuration.emitFrames,
            settings: settings,
            streamCreator: streamCreator,
            type: .client,
            preferHuffmanEncoding: configuration.preferHuffmanEncoding,
            logger: logger,
            inboundStreamInitializer: .closure(inboundPushStreamInitializer),
            internalInboundStreamInitializer: internalInboundStreamInitializer,
            // The `rttProvider` closure and `gracefulShutdownRTTMultiplier` is not used for clients, only servers use
            // it. We only pass values here because the initializer requires it.
            rttProvider: { .milliseconds(100) },
            gracefulShutdownRTTMultiplier: 1
        )
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if self.context != nil {
            fatalError("HTTP3ConnectionHandler must only be added to one Channel")
        }
        self.context = context
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        // Break the reference cycle
        self.coordinator.emitConnectionError = { _ in }
    }

    public func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        self.logger.debug("Initialising connection")
        self.coordinator.initialize()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.logger.debug("Connection became inactive")
        switch self.inboundStreamInitializer {
        case .multiplexer(let mux):
            mux.finish()
        case .closure:
            break
        }
        // If there is still an open stream then something is wrong in our implementation because we should have
        // shut the child channels before shutting the connection.
        // If this is triggered, most likely theres a mistake in the way the connection state machine remembers which streams are open,
        // or in the way the channels notify the state machine when they open/close.
        self.coordinator.assertNoOpenStreams()
        context.fireChannelInactive()
    }

    /// Ask the handler to initialize a new incoming stream. This must be called for every incoming QUIC stream _before_ that stream channel is activated.
    /// - Precondition: You must call this function on the eventloop.
    public func inboundStreamReceived(_ streamChannel: any Channel) -> EventLoopFuture<Void> {
        self.logger.trace("Connection got inbound stream")
        if let sync = streamChannel.syncOptions {
            let result = Result { try sync.getOption(.quicStreamID) }
            return self.setupNewInboundChannel(streamChannel, streamID: result)
        } else {
            let streamID: EventLoopFuture<UInt64> = streamChannel.getOption(.quicStreamID)
            return streamID.assumeIsolated().flatMap {
                self.setupNewInboundChannel(streamChannel, streamID: .success($0))
            }.nonisolated()
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard let quicError = error as? QUICConnectionError, quicError.isApplication else {
            self.logger.debug("HTTP3ConnectionHandler caught error", metadata: [LoggingKeys.error: "\(error)"])
            context.fireErrorCaught(error)
            return
        }
        // RFC 9114 § 8: Receipt of an unknown error code MUST be treated as equivalent to H3_NO_ERROR.
        let h3Code = HTTP3ErrorCode(rawValue: quicError.code) ?? .noError
        self.logger.debug(
            "HTTP3ConnectionHandler caught error",
            metadata: [LoggingKeys.error: "\(h3Code)", LoggingKeys.reason: "\(quicError.reason)"]
        )
        @inline(never)
        func remoteConnectionError(
            message: String,
            errorCode: HTTP3ErrorCode,
            location: HTTP3Error.SourceLocation
        ) -> HTTP3Error {
            HTTP3Error(
                code: .remoteConnectionError,
                message: message,
                cause: nil,
                errorCode: errorCode,
                location: location
            )
        }
        let h3Error = remoteConnectionError(message: quicError.reason, errorCode: h3Code, location: .here())
        self.coordinator.caughtRemoteError(h3Error)
        context.fireErrorCaught(h3Error)
    }

    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.logger.trace("HTTP3ConnectionHandler.close", metadata: ["mode": "\(mode)"])
        self.coordinator.shutdownConnectionImmediately()
        context.close(mode: mode, promise: promise)
    }

    private func setupNewInboundChannel(
        _ streamChannel: any Channel,
        streamID streamIDResult: Result<UInt64, any Error>
    ) -> EventLoopFuture<Void> {
        let streamID: UInt64
        switch streamIDResult {
        case .success(let id):
            streamID = id
        case .failure(let cause):
            return streamChannel.eventLoop.makeFailedFuture(
                HTTP3Error(
                    code: .unableToFindStreamID,
                    message: "Unable to find stream ID for incoming stream",
                    cause: cause,
                    errorCode: .internalError,
                    location: .here()
                )
            )
        }
        self.logger.trace("Connection got inbound stream", metadata: [LoggingKeys.quicStreamID: "\(streamID)"])
        switch self.inboundStreamInitializer {
        case .closure(let closure):
            return self.coordinator.inboundStreamInitializer(
                parameters: .init(channel: streamChannel, streamID: .init(rawValue: streamID)),
                addTypeHandlers: self.addTypeHandlers,
                userInboundStreamInitializer: closure,
                internalInboundStreamInitializer: self.internalInboundStreamInitializer,
                onUserStream: { _ in }
            )
        case .multiplexer(let multiplexer):
            return self.coordinator.inboundStreamInitializer(
                parameters: .init(channel: streamChannel, streamID: .init(rawValue: streamID)),
                addTypeHandlers: self.addTypeHandlers,
                userInboundStreamInitializer: multiplexer.initialize(parameters:),
                internalInboundStreamInitializer: self.internalInboundStreamInitializer,
                onUserStream: { multiplexer.yield(output: $0) }
            )
        }
    }

    /// Create a new request stream on this connection.
    /// - Parameter streamInitializer: Closure called before activation, so you can configure the Channel.
    /// - Returns: The result of the stream initializer.
    public func createRequestStream<InitializerOutput: Sendable>(
        streamInitializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<InitializerOutput>
    ) -> EventLoopFuture<InitializerOutput> {
        self.coordinator.createOutboundRequestStream(
            addTypeHandlers: self.addTypeHandlers,
            streamInitializer: streamInitializer
        )
    }

    /// Exposed for testing
    package func createUnidirectionalStream<InitializerOutput: Sendable>(
        ofType type: HTTP3StreamType.Unidirectional,
        streamInitializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<InitializerOutput>
    ) -> EventLoopFuture<InitializerOutput> {
        self.coordinator.createOutboundUnidirectionalStream(ofType: type, initializer: streamInitializer)
    }

    /// Send a GOAWAY frame to the remote peer.
    /// - Throws: If the given ID is not valid, for example, if it is higher than a previously given ID.
    /// - Note: If this is a client, this will not actually close the channel, it's fine to keep making requests after
    ///   telling the server to go away.
    public func sendGoaway(id: HTTP3GoawayID) throws {
        try self.coordinator.sendGoaway(goawayID: id)
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            // This event signals that the connection should be gracefully shutdown. We respond by sending GOAWAY frames
            // as described in RFC 9114 § 5.2 so the peer knows which streams will and won't be processed.
            do {
                try self.initiateGracefulShutdown()
            } catch {
                context.fireErrorCaught(error)
            }
            context.fireUserInboundEventTriggered(event)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    /// Initiates the graceful shutdown procedure described in RFC 9114 § 5.2 by sending GOAWAY frames to the peer.
    ///
    /// Servers send two GOAWAY frames:
    ///
    /// 1. The first frame is sent immediately with its identifier set to the maximum permitted value. This will inform
    ///    the client that no further streams will be processed by this endpoint.
    /// 2. The second frame is sent after a delay (the QUIC RTT estimate, optionally amplified by the multiplier) with
    ///    its identifier set to next expected client-initiated bidirectional stream ID. This will inform the client
    ///    that all in-flight streams the server has received will be processed.
    ///
    /// Clients only send a single GOAWAY frame with its identifier set to 0. This is because we don't support push
    /// streams yet.
    func initiateGracefulShutdown() throws {
        // If we have already initiated graceful shutdown before, return.
        guard self.coordinator.canInitiateGracefulShutdown() else {
            return
        }

        let goawayID: HTTP3GoawayID =
            switch self.type {
            case .client:
                // Clients never send a MAX_PUSH_ID frame because we don't support push streams yet. As such, the server
                // cannot initiate push streams, meaning clients never process push streams. Per RFC 9114 § 5.2
                // "Requests or pushes with the indicated identifier or greater are rejected (Section 4.1.1) by the
                // sender of the GOAWAY. This identifier MAY be zero if no requests or pushes were processed.", so 0 is
                // a valid GOAWAY identifier to send.
                HTTP3GoawayID(rawValue: 0)

            case .server:
                .maxServerValue
            }

        do {
            try self.coordinator.sendGoaway(goawayID: goawayID)
        } catch {
            self.logger.warning(
                "Failed to send GOAWAY during graceful shutdown",
                metadata: [LoggingKeys.error: "\(error)"]
            )

            throw error
        }

        // We send a second GOAWAY frame for servers.
        guard case .server = self.type else { return }

        // Per RFC 9114 § 5.2:
        // "After allowing time for any in-flight requests or pushes to arrive, the endpoint can send another GOAWAY
        //  frame indicating which requests or pushes it might accept before the end of the connection"
        //
        // We implement the "After allowing time for any in-flight requests or pushes to arrive" part by waiting for
        // the RTT estimate that the QUIC layer computes (optionally amplified by the multiplier).
        let delay = self.gracefulShutdownDelay()

        // After `delay`, send a second GOAWAY frame (with the ID set to the *next* client-initiated bidirectional
        // stream ID). This will inform the client that all in-flight streams the server has received will be processed.
        self.sendFinalGoaway(in: delay)
    }

    /// Returns the current RTT estimate obtained from `self.rttProvider`, multiplied by
    /// `self.gracefulShutdownRTTMultiplier`.
    func gracefulShutdownDelay() -> TimeAmount {
        let rtt = self.rttProvider()

        let delay = rtt * self.gracefulShutdownRTTMultiplier

        self.logger.debug(
            "Computed delay between first and second GOAWAY frames from RTT estimate",
            metadata: [
                "rtt": "\(rtt)",
                "multiplier": "\(self.gracefulShutdownRTTMultiplier)",
                "delay": "\(delay)",
            ]
        )

        return delay
    }

    /// Sends the second GOAWAY frame as part of the server's two-phase graceful shutdown sequence.
    ///
    /// Per RFC 9114 § 5.2, requests on streams with a stream ID *equal to or greater than* the GOAWAY's identifier
    /// are rejected. Therefore, the GOAWAY identifier is set to the next expected client-initiated bidirectional stream
    /// ID: this informs the client that the server will process all streams it has already received and will reject any
    /// other streams the client initiated after the server started sending the first GOAWAY.
    func sendFinalGoaway(in delay: TimeAmount) {
        // Only send the second GOAWAY for servers.
        guard case .server = self.type else { return }

        guard let context = self.context else { return }
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)

        let scheduledTask = context.eventLoop.scheduleTask(in: delay) {
            let extractedSelf = loopBoundSelf.value

            guard let nextStreamID = extractedSelf.coordinator.nextExpectedClientInitiatedBidirectionalStreamID()
            else {
                extractedSelf.logger.debug(
                    "Cannot send final GOAWAY because the connection state machine is not in the initialized state"
                )
                return
            }
            let goawayID = HTTP3GoawayID(rawValue: nextStreamID.rawValue)

            do {
                try extractedSelf.coordinator.sendGoaway(goawayID: goawayID)
            } catch {
                extractedSelf.logger.warning(
                    "Failed to send the final GOAWAY during graceful shutdown",
                    metadata: [LoggingKeys.error: "\(error)"]
                )

                throw error
            }
        }

        // Propagate the error thrown inside the `scheduleTask` callback
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        scheduledTask.futureResult.whenFailure { error in
            loopBoundContext.value.fireErrorCaught(error)
        }
    }
}

@available(*, unavailable)
extension HTTP3ConnectionHandler: Sendable {}

/// Specify config options for a HTTP/3 server.
public struct HTTP3ServerConfiguration: Sendable {
    /// If true, the inbound and output type of all stream channels of all connections on this server will be HTTP3Frame.
    /// Otherwise, the inbound will be HTTPRequestPart and the outbound will be HTTPResponsePart.
    public var emitFrames = false

    /// If true, Huffman encoding will be used where applicable, e.g. for header field sections.
    /// - Note: Huffman encoding will not be used if it would result in a larger payload than not using it, even if this property is true.
    public var preferHuffmanEncoding = true

    /// A closure that returns the current QUIC round-trip time estimate, obtained from the underlying QUIC
    /// implementation.
    public var rttProvider: (@Sendable () -> TimeAmount)

    /// The multiplier applied to the result returned by ``rttProvider``.
    ///
    /// The multiplied result is used as the period to wait between sending the first GOAWAY frame and the second final
    /// GOAWAY frame during graceful shutdown. Defaults to 1.
    public var gracefulShutdownRTTMultiplier: Int = 1

    private init(rttProvider: @escaping (@Sendable () -> TimeAmount)) {
        self.rttProvider = rttProvider
    }

    /// The default configuration.
    public static var defaults: Self {
        Self(rttProvider: { .milliseconds(100) })
    }
}

/// Specify config options for a HTTP/3 client.
public struct HTTP3ClientConfiguration: Sendable {
    /// If true, the inbound and output type of all stream channels of all connections from this client will be HTTP3Frame.
    /// Otherwise, the inbound will be HTTPResponsePart and the outbound will be HTTPRequestPart.
    public var emitFrames = false

    /// If true, Huffman encoding will be used where applicable, e.g. for header field sections.
    /// - Note: Huffman encoding will not be used if it would result in a larger payload than not using it, even if this property is true.
    public var preferHuffmanEncoding = true

    private init() {}

    /// The default configuration.
    public static var defaults: Self {
        Self()
    }
}
