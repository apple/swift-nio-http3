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
import Logging
import NIOCore
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOQUICHelpers

import class NIOQUIC.AsyncVerifier
import class NIOQUIC.Authenticator
import struct NIOQUIC.QUICConfiguration
import class NIOQUIC.QUICHandler
import struct NIOQUIC.QUICMetrics
import struct NIOQUIC.QUICStreamCreator

typealias QUICHTTP3ConnectionHandler = HTTP3ConnectionHandler<QUICStreamCreator>

// MARK: Configure with async interface
@available(anyAppleOS 26, *)
extension ChannelPipeline.SynchronousOperations {
    /// Setup a HTTP/3 server pipeline on a UDP channel.
    ///
    /// - Parameters:
    ///   - channel: The UDP channel.
    ///   - configuration: The ``HTTP3ServerConfiguration``.
    ///   - settings: The `HTTP3Settings` to use for all incoming connections.
    ///   - quicConfiguration: The `QUICConfiguration` to be used.
    ///   - metrics: The metrics.
    ///   - logger: The logger.
    ///   - inboundRequestStreamInitializer: Closure to run for each incoming stream. Must be synchronous.
    /// - Returns: A ``HTTP3ServerConnectionMultiplexer``. Use this to iterate incoming connections.
    /// - Throws: If adding the relevant handlers fails.
    func configureHTTP3Server<Output: Sendable>(
        channel: any Channel,
        configuration: HTTP3ServerConfiguration = .defaults,
        settings: HTTP3Settings = .init(),
        quicConfiguration: QUICConfiguration,
        metrics: QUICMetrics? = nil,
        logger: Logger,
        inboundRequestStreamInitializer:
            @Sendable @escaping (HTTP3StreamInitializerParameters)
            -> EventLoopFuture<Output>
    ) throws -> HTTP3ServerConnectionMultiplexer<Output, QUICStreamCreator> {
        let authenticator: Authenticator? =
            switch quicConfiguration.authenticationConfiguration {
            case .rawPublicKeys:
                nil
            case .x509Certificates(let certificateChainFilePath, let privateKeyFilePath):
                try Authenticator(certificateFilePath: certificateChainFilePath, privateKeyFilePath: privateKeyFilePath)
            case .none:
                fatalError("No QUIC authentication configuration specified.")
            }
        let connectionMultiplexer = HTTP3ServerConnectionMultiplexer<Output, QUICStreamCreator>()
        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: quicConfiguration,
            asyncVerifier: nil,
            authenticator: authenticator,
            logger: logger,
            metrics: metrics,
            inboundConnectionInitializer: { connectionChannel, streamCreator in
                connectionChannel.eventLoop.makeCompletedFuture {
                    let loopBoundHandler: NIOLoopBoundBox<HTTP3ConnectionHandler<QUICStreamCreator>?> = .init(
                        nil,
                        eventLoop: connectionChannel.eventLoop
                    )
                    let connection = HTTP3ServerConnection(
                        connectionHandler: loopBoundHandler,
                        inboundStreamInitializer: inboundRequestStreamInitializer
                    )
                    let h3Handler = HTTP3ConnectionHandler.server(
                        eventLoop: connectionChannel.eventLoop,
                        configuration: configuration,
                        settings: settings,
                        streamCreator: streamCreator,
                        logger: logger,
                        connection: connection
                    )
                    loopBoundHandler.value = h3Handler
                    try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                    connectionMultiplexer.yield(connection: connection)
                }
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self).flatMap {
                    h3Handler in
                    h3Handler.inboundStreamReceived(streamChannel)
                }
            },
            noMoreConnections: {
                connectionMultiplexer.finish()
            }
        )
        try self.addHandler(quicHandler)
        return connectionMultiplexer
    }

    /// Setup a HTTP/3 client pipeline on a UDP channel.
    ///
    /// - Parameters:
    ///   - channel: The UDP channel.
    ///   - configuration: The ``HTTP3ClientConfiguration``.
    ///   - settings: The `HTTP3Settings` to use for all outgoing connections.
    ///   - quicConfiguration: The `QUICConfiguration` to be used.
    ///   - metrics: The metrics.
    ///   - logger: The logger.
    ///   - internalInboundStreamInitializer: A closure which will be called for every incoming non-push stream.
    /// - Returns: A ``HTTP3ClientConnectionMultiplexer``. Use this to create outgoing connections.
    /// - Throws: If adding the relevant handlers fails.
    func configureHTTP3Client(
        channel: any Channel,
        configuration: HTTP3ClientConfiguration = .defaults,
        settings: HTTP3Settings = .init(),
        quicConfiguration: QUICConfiguration,
        metrics: QUICMetrics? = nil,
        logger: Logger,
        internalInboundStreamInitializer: (
            @Sendable (any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>
        )? = nil
    ) throws -> HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator> {
        let asyncVerifier: AsyncVerifier?
        switch quicConfiguration.verificationConfiguration {
        case .rawPublicKeys:
            asyncVerifier = nil
        case .x509Certificates(let trustRootsFilePath):
            guard let trustRootsFilePath else {
                fatalError("Trust roots file path not set.")
            }
            asyncVerifier = try AsyncVerifier(trustRootsPath: trustRootsFilePath, eventLoop: channel.eventLoop)
        case .none:
            fatalError("No QUIC verification configuration specified.")
        }
        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: quicConfiguration,
            asyncVerifier: asyncVerifier,
            authenticator: nil,
            logger: logger,
            metrics: metrics,
            inboundConnectionInitializer: { _, _ in
                fatalError()
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self).flatMap {
                    h3Handler in
                    h3Handler.inboundStreamReceived(streamChannel)
                }
            },
            noMoreConnections: {}
        )
        try self.addHandler(quicHandler)

        let connectionMultiplexer = HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator>(
            eventLoop: self.eventLoop,
            createNewConnection: NIOLoopBound(
                QUICConnectionCreator(
                    quicHandler: quicHandler,
                    connectionInitializer: { connectionChannel, streamCreator in
                        connectionChannel.eventLoop.makeCompletedFuture {
                            let h3Handler = HTTP3ConnectionHandler.client(
                                eventLoop: connectionChannel.eventLoop,
                                configuration: configuration,
                                settings: settings,
                                streamCreator: streamCreator,
                                logger: logger,
                                inboundPushStreamInitializer: { _ in
                                    fatalError()
                                },
                                internalInboundStreamInitializer: internalInboundStreamInitializer
                            )
                            try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                            return connectionChannel
                        }
                    },
                    inboundStreamInitializer: { streamChannel in
                        streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self)
                            .flatMap {
                                h3Handler in
                                h3Handler.inboundStreamReceived(streamChannel)
                            }
                    }
                ),
                eventLoop: self.eventLoop
            )
        )

        return connectionMultiplexer
    }
}

// MARK: Configure without async interface

@available(anyAppleOS 26, *)
extension ChannelPipeline.SynchronousOperations {
    /// Setup a HTTP/3 server pipeline on a UDP channel.
    ///
    /// - Parameters:
    ///   - channel: The UDP channel.
    ///   - configuration: The ``HTTP3ServerConfiguration``.
    ///   - settings: The `HTTP3Settings` to use for all incoming connections.
    ///   - quicConfiguration: The `QUICConfiguration` to be used.
    ///   - metrics: The metrics.
    ///   - logger: The logger.
    ///   - inboundConnectionInitializer: Closure to run for each incoming connection.
    ///   - inboundRequestStreamInitializer: Closure to run for each incoming request stream.
    ///   - internalInboundStreamInitializer: Closure to run for each incoming non-request stream.
    /// - Throws: If adding the relevant handlers fails.
    func configureHTTP3Server(
        channel: any Channel,
        configuration: HTTP3ServerConfiguration = .defaults,
        settings: HTTP3Settings = .init(),
        quicConfiguration: QUICConfiguration,
        metrics: QUICMetrics? = nil,
        logger: Logger,
        inboundConnectionInitializer: @Sendable @escaping (any Channel) -> EventLoopFuture<Void>,
        inboundRequestStreamInitializer:
            @Sendable @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<
                Void
            >,
        internalInboundStreamInitializer: (
            @Sendable (any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>
        )?
    ) throws {
        let authenticator: Authenticator? =
            switch quicConfiguration.authenticationConfiguration {
            case .rawPublicKeys:
                nil
            case .x509Certificates(let certificateChainFilePath, let privateKeyFilePath):
                try Authenticator(certificateFilePath: certificateChainFilePath, privateKeyFilePath: privateKeyFilePath)
            case .none:
                fatalError("No QUIC authentication configuration specified.")
            }
        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: quicConfiguration,
            asyncVerifier: nil,
            authenticator: authenticator,
            logger: logger,
            metrics: metrics,
            inboundConnectionInitializer: { connectionChannel, streamCreator in
                connectionChannel.eventLoop.makeCompletedFuture {
                    let h3Handler = HTTP3ConnectionHandler.server(
                        eventLoop: connectionChannel.eventLoop,
                        configuration: configuration,
                        settings: settings,
                        streamCreator: streamCreator,
                        logger: logger,
                        inboundRequestStreamInitializer: inboundRequestStreamInitializer,
                        internalInboundStreamInitializer: internalInboundStreamInitializer
                    )
                    try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                }.flatMap { _ in
                    inboundConnectionInitializer(connectionChannel)
                }
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self).flatMap {
                    h3Handler in
                    h3Handler.inboundStreamReceived(streamChannel)
                }
            },
            noMoreConnections: {}
        )
        try channel.pipeline.syncOperations.addHandler(quicHandler)
    }
}
