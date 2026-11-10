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

@available(anyAppleOS 27, *)
extension ChannelPipeline.SynchronousOperations {
    /// Configures a QUIC connection channel's pipeline to speak HTTP/3 as a server.
    ///
    /// This operation **must** be called on the event loop, typically from the QUIC implementation's inbound connection
    /// initializer. Inbound stream channels on the connection must be passed to
    /// ``HTTP3ConnectionHandler/inboundStreamReceived(_:)``.
    ///
    /// - Parameters:
    ///   - configuration: Configuration for the connection.
    ///   - settings: The `HTTP3Settings` to send to the peer.
    ///   - streamCreator: For creating outbound streams.
    ///   - logger: A logger.
    ///   - streamInitializer: Called for every inbound request stream.
    /// - Returns: A ``HTTP3ServerConnection`` for iterating the inbound request streams.
    /// - Throws: If the handler could not be added to the pipeline.
    @_spi(HTTP3AsyncInterface)
    public func configureAsyncHTTP3ServerPipeline<
        Output: Sendable,
        StreamCreator: QUICStreamCreator & SendableMetatype
    >(
        configuration: HTTP3ServerConfiguration = .defaults,
        settings: HTTP3Settings = .init(),
        streamCreator: StreamCreator,
        logger: Logger,
        streamInitializer: @escaping @Sendable (HTTP3StreamInitializerParameters) -> EventLoopFuture<Output>
    ) throws -> HTTP3ServerConnection<Output> {
        let (stream, continuation) = AsyncStream<Output>.makeStream()
        let handler = HTTP3ConnectionHandler.server(
            eventLoop: self.eventLoop,
            configuration: configuration,
            settings: settings,
            streamCreator: streamCreator,
            logger: logger,
            inboundRequestStreamInitializer: .yielding(to: continuation, streamInitializer: streamInitializer),
            internalInboundStreamInitializer: nil
        )
        try self.addHandler(handler)
        return HTTP3ServerConnection(inbound: .init(stream: stream))
    }

    /// Configures a QUIC connection channel's pipeline to speak HTTP/3 as a client.
    ///
    /// This operation **must** be called on the event loop, typically from the QUIC implementation's outbound
    /// connection initializer.
    ///
    /// - Parameters:
    ///   - configuration: Configuration for the connection.
    ///   - settings: The `HTTP3Settings` to send to the peer.
    ///   - streamCreator: For creating outbound streams.
    ///   - logger: A logger.
    ///   - inboundPushStreamInitializer: Called for every inbound push stream. This argument is currently ignored as
    ///     push streams are not supported yet. See https://github.com/apple/swift-nio-http3/issues/1.
    /// - Returns: A ``HTTP3ClientConnection`` for creating request streams.
    /// - Throws: If the handler could not be added to the pipeline.
    @_spi(HTTP3AsyncInterface)
    public func configureAsyncHTTP3ClientPipeline<
        Output: Sendable,
        StreamCreator: QUICStreamCreator & SendableMetatype
    >(
        configuration: HTTP3ClientConfiguration = .defaults,
        settings: HTTP3Settings = .init(),
        streamCreator: StreamCreator,
        logger: Logger,
        inboundPushStreamInitializer: @Sendable @escaping (HTTP3StreamInitializerParameters) throws -> Output
    ) throws -> HTTP3ClientConnection<Output, StreamCreator> {
        let handler = HTTP3ConnectionHandler.client(
            eventLoop: self.eventLoop,
            configuration: configuration,
            settings: settings,
            streamCreator: streamCreator,
            logger: logger,
            // TODO: https://github.com/apple/swift-nio-http3/issues/1
            // Push streams are not supported yet.
            inboundPushStreamInitializer: { $0.channel.eventLoop.makeSucceededVoidFuture() }
        )
        try self.addHandler(handler)
        return HTTP3ClientConnection(
            h3Handler: NIOLoopBound(handler, eventLoop: self.eventLoop),
            inboundPushStreamInitializer: inboundPushStreamInitializer
        )
    }
}
