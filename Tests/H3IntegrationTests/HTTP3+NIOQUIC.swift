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
import Logging
import NIOCore
import NIOQUICHelpers

import class NIOQUIC.AsyncVerifier
import class NIOQUIC.Authenticator
import struct NIOQUIC.QUICConfiguration
import class NIOQUIC.QUICHandler
import enum NIOQUIC.QUICStreamChannels
import struct NIOQUIC.QUICStreamCreator

@testable import NIOHTTP3

@available(anyAppleOS 27, *)
typealias QUICHTTP3ConnectionHandler = HTTP3ConnectionHandler<QUICStreamCreator, HTTP3ClosureInboundStreamInitializer>

// MARK: Configure with async interface
extension ChannelPipeline.SynchronousOperations {
    /// Setup a HTTP/3 server pipeline on a UDP channel.
    ///
    /// - Parameters:
    ///   - channel: The UDP channel.
    ///   - configuration: The ``HTTP3ServerConfiguration``.
    ///   - settings: The `HTTP3Settings` to use for all incoming connections.
    ///   - quicConfiguration: The `QUICConfiguration` to be used.
    ///   - logger: The logger.
    ///   - inboundRequestStreamInitializer: Closure to run for each incoming stream.
    /// - Returns: An asynchronous sequence of the incoming connections, alongside the associated connection channel.
    /// - Throws: If adding the relevant handlers fails.
    @available(anyAppleOS 27, *)
    func configureHTTP3Server<Output: Sendable>(
        channel: any Channel,
        configuration: HTTP3ServerConfiguration = .defaults,
        settings: HTTP3Settings = .init(),
        quicConfiguration: QUICConfiguration,
        logger: Logger,
        inboundRequestStreamInitializer:
            @Sendable @escaping (HTTP3StreamInitializerParameters)
            -> EventLoopFuture<Output>
    ) throws -> AsyncStream<(any Channel, HTTP3ServerConnection<Output>)> {
        let authenticator: Authenticator? =
            switch quicConfiguration.authenticationConfiguration {
            case .rawPublicKeys:
                nil
            case .x509Certificates(let certificateChainFilePath, let privateKeyFilePath):
                try Authenticator(certificateFilePath: certificateChainFilePath, privateKeyFilePath: privateKeyFilePath)
            case .none:
                fatalError("No QUIC authentication configuration specified.")
            }
        let (connectionStream, continuation) = AsyncStream<(any Channel, HTTP3ServerConnection<Output>)>.makeStream()
        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: quicConfiguration,
            asyncVerifier: nil,
            authenticator: authenticator,
            logger: logger,
            inboundConnectionInitializer: { connectionChannel, streamCreator in
                connectionChannel.eventLoop.makeCompletedFuture {
                    let connection = try connectionChannel.pipeline.syncOperations.configureAsyncHTTP3ServerPipeline(
                        configuration: configuration,
                        settings: settings,
                        streamCreator: streamCreator,
                        logger: logger,
                        streamInitializer: inboundRequestStreamInitializer
                    )
                    continuation.yield((connectionChannel, connection))
                }
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(
                    type: HTTP3ConnectionHandler<QUICStreamCreator, HTTP3AsyncInboundStreamInitializer<Output>>.self
                ).flatMap { h3Handler in
                    h3Handler.inboundStreamReceived(streamChannel)
                }
            },
            noMoreConnections: {
                continuation.finish()
            }
        )
        try self.addHandler(quicHandler)
        return connectionStream
    }

    /// Setup a HTTP/3 client on a UDP channel.
    ///
    /// - Parameters:
    ///   - channel: The UDP channel.
    ///   - configuration: The ``HTTP3ClientConfiguration``.
    ///   - settings: The `HTTP3Settings` to use for all outgoing connections.
    ///   - quicConfiguration: The `QUICConfiguration` to be used.
    ///   - logger: The logger.
    ///   - internalInboundStreamInitializer: A closure which will be called for every incoming non-push stream.
    /// - Returns: A ``TestHTTP3Client``. Use this to create outgoing connections.
    /// - Throws: If adding the relevant handlers fails.
    @available(anyAppleOS 27, *)
    func configureHTTP3Client(
        channel: any Channel,
        configuration: HTTP3ClientConfiguration = .defaults,
        settings: HTTP3Settings = .init(),
        quicConfiguration: QUICConfiguration,
        logger: Logger,
        internalInboundStreamInitializer: (
            @Sendable (any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>
        )? = nil
    ) throws -> TestHTTP3Client {
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
            inboundConnectionInitializer: { _, _ in
                fatalError()
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(type: QUICHTTP3ConnectionHandler.self).flatMap {
                    h3Handler in
                    h3Handler.inboundStreamReceived(streamChannel)
                }
            },
            noMoreConnections: {}
        )
        try self.addHandler(quicHandler)

        return TestHTTP3Client(
            quicHandler: NIOLoopBound(quicHandler, eventLoop: self.eventLoop),
            configuration: configuration,
            settings: settings,
            logger: logger,
            internalInboundStreamInitializer: internalInboundStreamInitializer
        )
    }
}

// MARK: Configure without async interface

extension ChannelPipeline.SynchronousOperations {
    /// Setup a HTTP/3 server pipeline on a UDP channel.
    ///
    /// - Parameters:
    ///   - channel: The UDP channel.
    ///   - configuration: The ``HTTP3ServerConfiguration``.
    ///   - settings: The `HTTP3Settings` to use for all incoming connections.
    ///   - quicConfiguration: The `QUICConfiguration` to be used.
    ///   - logger: The logger.
    ///   - inboundConnectionInitializer: Closure to run for each incoming connection.
    ///   - inboundRequestStreamInitializer: Closure to run for each incoming request stream.
    ///   - internalInboundStreamInitializer: Closure to run for each incoming non-request stream.
    /// - Throws: If adding the relevant handlers fails.
    @available(anyAppleOS 27, *)
    func configureHTTP3Server(
        channel: any Channel,
        configuration: HTTP3ServerConfiguration = .defaults,
        settings: HTTP3Settings = .init(),
        quicConfiguration: QUICConfiguration,
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
            inboundConnectionInitializer: { connectionChannel, streamCreator in
                connectionChannel.eventLoop.makeCompletedFuture {
                    let h3Handler = HTTP3ConnectionHandler.server(
                        eventLoop: connectionChannel.eventLoop,
                        configuration: configuration,
                        settings: settings,
                        streamCreator: streamCreator,
                        logger: logger,
                        inboundRequestStreamInitializer: HTTP3ClosureInboundStreamInitializer(
                            inboundRequestStreamInitializer
                        ),
                        internalInboundStreamInitializer: internalInboundStreamInitializer
                    )
                    try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                }.flatMap { _ in
                    inboundConnectionInitializer(connectionChannel)
                }
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(type: QUICHTTP3ConnectionHandler.self).flatMap {
                    h3Handler in
                    h3Handler.inboundStreamReceived(streamChannel)
                }
            },
            noMoreConnections: {}
        )
        try channel.pipeline.syncOperations.addHandler(quicHandler)
    }
}

/// Creates outbound HTTP/3 connections over a QUIC client channel.
@available(anyAppleOS 27, *)
struct TestHTTP3Client: Sendable {
    let quicHandler: NIOLoopBound<QUICHandler<QUICStreamChannels>>
    let configuration: HTTP3ClientConfiguration
    let settings: HTTP3Settings
    let logger: Logger
    let internalInboundStreamInitializer:
        (@Sendable (any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>)?

    /// Create an outbound connection using the async interface.
    /// - Parameters:
    ///   - serverName: The server to connect to.
    ///   - remoteAddress: The server's address.
    ///   - inboundPushStreamInitializer: A closure that configures the incoming push stream channel.
    /// - Returns: The connection channel and a ``HTTP3ClientConnection`` which can be used to create outbound requests.
    /// - Throws: If the connection cannot be created.
    func createConnection<Output: Sendable>(
        serverName: String,
        remoteAddress: SocketAddress,
        inboundPushStreamInitializer: @Sendable @escaping (HTTP3StreamInitializerParameters) throws -> Output
    ) async throws -> (any Channel, HTTP3ClientConnection<Output, QUICStreamCreator>) {
        try await self.connect(serverName: serverName, remoteAddress: remoteAddress) { channel, streamCreator in
            channel.eventLoop.makeCompletedFuture {
                let connection = try channel.pipeline.syncOperations.configureAsyncHTTP3ClientPipeline(
                    configuration: self.configuration,
                    settings: self.settings,
                    streamCreator: streamCreator,
                    logger: self.logger,
                    inboundPushStreamInitializer: inboundPushStreamInitializer
                )
                return (channel, connection)
            }
        }.get()
    }

    /// Create an outbound connection channel with a `HTTP3ConnectionHandler` in the pipeline.
    /// - Parameters:
    ///   - serverName: The server to connect to.
    ///   - remoteAddress: The server's address.
    ///   - connectionInitializer: A closure that configures the connection channel.
    /// - Returns: The connection channel.
    func createConnectionChannel(
        serverName: String,
        remoteAddress: SocketAddress,
        connectionInitializer: (@Sendable (any Channel) -> EventLoopFuture<Void>)?
    ) -> EventLoopFuture<any Channel> {
        self.connect(serverName: serverName, remoteAddress: remoteAddress) { channel, streamCreator in
            channel.eventLoop.makeCompletedFuture {
                let h3Handler = HTTP3ConnectionHandler.client(
                    eventLoop: channel.eventLoop,
                    configuration: self.configuration,
                    settings: self.settings,
                    streamCreator: streamCreator,
                    logger: self.logger,
                    inboundPushStreamInitializer: HTTP3ClosureInboundStreamInitializer { _ in fatalError() },
                    internalInboundStreamInitializer: self.internalInboundStreamInitializer
                )
                try channel.pipeline.syncOperations.addHandler(h3Handler)
            }.flatMap {
                connectionInitializer?(channel) ?? channel.eventLoop.makeSucceededVoidFuture()
            }.map {
                channel
            }
        }
    }

    /// Create an outbound connection and configure the connection channel with `connectionInitializer`.
    /// - Parameters:
    ///   - serverName: The server to connect to.
    ///   - remoteAddress: The server's address.
    ///   - connectionInitializer: A closure that configures the connection channel.
    /// - Returns: The output of `connectionInitializer`.
    private func connect<Output: Sendable>(
        serverName: String,
        remoteAddress: SocketAddress,
        connectionInitializer: @escaping @Sendable (any Channel, QUICStreamCreator) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        self.quicHandler.eventLoop.flatSubmit {
            let outputPromise = self.quicHandler.eventLoop.makePromise(of: Output.self)
            let connection = self.quicHandler.value.createOutboundConnection(
                serverName: serverName,
                remoteAddress: remoteAddress,
                connectionInitializer: { connectionChannel, streamCreator in
                    let output = connectionInitializer(connectionChannel, streamCreator)
                    output.cascade(to: outputPromise)
                    return output.map { _ in }
                },
                inboundStreamInitializer: { streamChannel in
                    streamChannel.parent!.pipeline.handler(type: QUICHTTP3ConnectionHandler.self)
                        .flatMap { h3Handler in
                            h3Handler.inboundStreamReceived(streamChannel)
                        }
                }
            )
            connection.cascadeFailure(to: outputPromise)
            return connection.flatMap { _ in outputPromise.futureResult }
        }
    }
}

@available(anyAppleOS 27, *)
extension Channel {
    /// Send a GOAWAY frame with the provided `id` from the `HTTP3ConnectionHandler` in this connection channel's
    /// pipeline.
    func sendHTTP3Goaway<InboundStreamInitializer: HTTP3InboundStreamInitializer>(
        id: HTTP3GoawayID,
        inboundStreamInitializer: InboundStreamInitializer.Type
    ) async throws {
        try await self.eventLoop.submit {
            try self.pipeline.syncOperations
                .handler(type: HTTP3ConnectionHandler<QUICStreamCreator, InboundStreamInitializer>.self)
                .sendGoaway(id: id)
        }.get()
    }
}
