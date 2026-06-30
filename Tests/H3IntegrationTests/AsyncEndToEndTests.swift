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
import HTTPTypes
import Logging
import NIOCore
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOHTTPTypes
import NIOPosix
import Testing
import X509

import struct NIOQUIC.QUICConfiguration
import struct NIOQUIC.QUICStreamCreator

struct AsyncEndToEndTests {
    private let eventLoopGroup = MultiThreadedEventLoopGroup.singleton

    private static let standardAuthenticationConfigurations: [AuthenticationConfiguration] = {
        [.keys, .certs]
    }()

    @Test(arguments: Self.standardAuthenticationConfigurations)
    @available(anyAppleOS 26, *)
    func asyncRoundtrip(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let serverLogger = Logger(label: "Server")
        let clientLogger = Logger(label: "Client")

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)
        let serverName: String
        switch credentials {
        case .rawKeys(let name, _, _, _):
            serverName = name
        case .certificates(let name, _, _, _):
            serverName = name
        }

        let (serverChannel, serverMultiplexer) = try await makeHTTP3Server(
            credentials: credentials,
            settings: .init(),
            logger: serverLogger
        )
        let (clientChannel, clientMultiplexer) = try await makeHTTP3Client(
            credentials: credentials,
            settings: .init(),
            logger: clientLogger
        )

        let testRequest = HTTPRequest(method: .get, scheme: "https", authority: "test", path: "/")
        let testResponse = HTTPResponse(status: .ok, headerFields: [.userAgent: "test"])

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Server
            group.addTask {
                for try await inboundConnection in serverMultiplexer.inboundConnections {
                    for try await inboundStream in inboundConnection.inboundStreams {
                        serverLogger.info("Got inbound stream")
                        try await inboundStream.executeThenClose { inboundParts, outbound in
                            var inboundPartIterator = inboundParts.makeAsyncIterator()
                            try await #expect(inboundPartIterator.next() == .head(testRequest))
                            try await #expect(inboundPartIterator.next() == .end())
                            try await #expect(inboundPartIterator.next() == nil)

                            try await outbound.write(.head(testResponse))
                            try await outbound.write(.body(.init(string: "Hello World")))
                            outbound.finish()
                        }
                    }
                }
            }
            // Client
            group.addTask {
                let clientConnection = try await clientMultiplexer.concurrencyView.createConnection(
                    serverName: serverName,
                    remoteAddress: serverChannel.localAddress!,
                    inboundPushStreamInitializer: { _ in
                        fatalError("Push streams not supported")
                    }
                )

                let requestStream = try await clientConnection.concurrencyView.createRequestStream {
                    let streamChannel = $0.channel
                    return streamChannel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                            wrappingChannelSynchronously: streamChannel,
                            configuration: .init(
                                isOutboundHalfClosureEnabled: true
                            )
                        )
                    }
                }

                clientLogger.info("Making request")
                try await requestStream.executeThenClose { inboundParts, outbound in
                    try await outbound.write(.head(testRequest))
                    outbound.finish()
                    var inboundPartIterator = inboundParts.makeAsyncIterator()
                    try await #expect(inboundPartIterator.next() == .head(testResponse))
                    try await #expect(inboundPartIterator.next() == .body(.init(string: "Hello World")))
                    try await #expect(inboundPartIterator.next() == .end())
                    try await #expect(inboundPartIterator.next() == nil)
                }

                // Shutdown
                clientLogger.info("Shutting down")
                try await clientChannel.close()

                serverLogger.info("Shutting down")
                try await serverChannel.close()
            }
            try await group.waitForAll()
        }
    }

    @Test(arguments: Self.standardAuthenticationConfigurations)
    @available(anyAppleOS 26, *)
    func goawayMidRequestWithHighID(authenticationConfiguration: AuthenticationConfiguration) async throws {
        // Send a goaway to the client in the middle of a request. See that the client can not make further requests.
        let serverLogger = Logger(label: "Server")
        let clientLogger = Logger(label: "Client")

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)
        let serverName: String
        switch credentials {
        case .rawKeys(let name, _, _, _):
            serverName = name
        case .certificates(let name, _, _, _):
            serverName = name
        }

        let (serverChannel, serverMultiplexer) = try await makeHTTP3Server(
            credentials: credentials,
            settings: .init(),
            logger: serverLogger
        )
        let (clientChannel, clientMultiplexer) = try await makeHTTP3Client(
            credentials: credentials,
            settings: .init(),
            logger: clientLogger
        )

        let testRequest = HTTPRequest(method: .get, scheme: "https", authority: "test", path: "/")
        let testResponse = HTTPResponse(status: .ok, headerFields: [.userAgent: "test"])

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Server
            group.addTask {
                // this server will only serve a single connection, then shut itself down.
                var inboundConnections = serverMultiplexer.inboundConnections.makeAsyncIterator()
                let inboundConnection = try #require(await inboundConnections.next())
                for try await inboundStream in inboundConnection.inboundStreams {
                    serverLogger.info("Got inbound stream")
                    try await inboundStream.executeThenClose { inboundParts, outbound in
                        var inboundPartIterator = inboundParts.makeAsyncIterator()
                        try await #expect(inboundPartIterator.next() == .head(testRequest))
                        try await #expect(inboundPartIterator.next() == .end())
                        try await #expect(inboundPartIterator.next() == nil)

                        // Tell the client to goaway, but with an id that won't affect this request
                        inboundConnection.sendGoaway(id: 100)

                        try await outbound.write(.head(testResponse))
                        try await outbound.write(.body(.init(string: "Hello World")))
                        outbound.finish()
                    }
                }
                serverLogger.info("Client has gone, shutting down server")
                try await serverChannel.close()
            }
            // Client
            group.addTask {
                let clientConnection = try await clientMultiplexer.concurrencyView.createConnection(
                    serverName: serverName,
                    remoteAddress: serverChannel.localAddress!,
                    inboundPushStreamInitializer: { _ in
                        fatalError("Push streams not supported")
                    }
                )

                let requestStream = try await clientConnection.concurrencyView.createRequestStream {
                    let streamChannel = $0.channel
                    return streamChannel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                            wrappingChannelSynchronously: streamChannel,
                            configuration: .init(
                                isOutboundHalfClosureEnabled: true
                            )
                        )
                    }
                }

                clientLogger.info("Making request")
                try await requestStream.executeThenClose { inboundParts, outbound in
                    try await outbound.write(.head(testRequest))
                    outbound.finish()
                    var inboundPartIterator = inboundParts.makeAsyncIterator()
                    try await #expect(inboundPartIterator.next() == .head(testResponse))
                    try await #expect(inboundPartIterator.next() == .body(.init(string: "Hello World")))
                    try await #expect(inboundPartIterator.next() == .end())
                    try await #expect(inboundPartIterator.next() == nil)
                }

                clientLogger.info("Making another request")

                // Further request streams can't be made
                await #expect(throws: HTTP3Error.self) {
                    try await clientConnection.concurrencyView.createRequestStream {
                        $0.channel.eventLoop.makeSucceededVoidFuture()
                    }
                }
            }
            try await group.waitForAll()
        }

        // cleanup
        try await clientChannel.close()
    }

    @Test(arguments: Self.standardAuthenticationConfigurations)
    @available(anyAppleOS 26, *)
    func goawayMidRequest(authenticationConfiguration: AuthenticationConfiguration) async throws {
        // Send a goaway to a client during a request, such that the goaway affects the request in flight.
        // See that the server rejects the request.
        let serverLogger = Logger(label: "Server")
        let clientLogger = Logger(label: "Client")

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)
        let serverName: String
        switch credentials {
        case .rawKeys(let name, _, _, _):
            serverName = name
        case .certificates(let name, _, _, _):
            serverName = name
        }

        let (serverChannel, serverMultiplexer) = try await makeHTTP3Server(
            credentials: credentials,
            settings: .init(),
            logger: serverLogger
        )
        let (clientChannel, clientMultiplexer) = try await makeHTTP3Client(
            credentials: credentials,
            settings: .init(),
            logger: clientLogger
        )

        let testRequest = HTTPRequest(method: .get, scheme: "https", authority: "test", path: "/")

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Server
            group.addTask {
                // this server will only serve a single connection, then shut itself down.
                var inboundConnections = serverMultiplexer.inboundConnections.makeAsyncIterator()
                let inboundConnection = try #require(await inboundConnections.next())
                for try await inboundStream in inboundConnection.inboundStreams {
                    serverLogger.info("Got inbound stream")
                    try await inboundStream.executeThenClose { inboundParts, outbound in
                        var inboundPartIterator = inboundParts.makeAsyncIterator()
                        try await #expect(inboundPartIterator.next() == .head(testRequest))
                        try await #expect(inboundPartIterator.next() == .end())
                        try await #expect(inboundPartIterator.next() == nil)

                        // Tell the client to goaway, with an id will affect this current request
                        inboundConnection.sendGoaway(id: 0)

                        // The stream has been reset and will close. Don't try to respond or wait for
                        // the automatic close - just let the closure complete without sending FIN.
                        // The channel is already closing due to RESET_STREAM from cancelStreamDueToSendingGoaway().
                    }
                }
                serverLogger.info("Client has gone, shutting down server")
                try await serverChannel.close()
            }
            // Client
            group.addTask {
                let clientRequestErrorPromise = clientChannel.eventLoop.makePromise(of: (any Error).self)
                defer {
                    clientRequestErrorPromise.fail(NeverFulfilled())
                }
                let clientConnection = try await clientMultiplexer.concurrencyView.createConnection(
                    serverName: serverName,
                    remoteAddress: serverChannel.localAddress!,
                    inboundPushStreamInitializer: { _ in
                        fatalError("Push streams not supported")
                    }
                )

                let requestStream = try await clientConnection.concurrencyView.createRequestStream {
                    let streamChannel = $0.channel
                    return streamChannel.eventLoop.makeCompletedFuture {
                        try streamChannel.pipeline.syncOperations.addHandler(
                            ErrorCatchingHandler(errorPromise: clientRequestErrorPromise)
                        )
                        return try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                            wrappingChannelSynchronously: streamChannel,
                            configuration: .init(
                                isOutboundHalfClosureEnabled: true
                            )
                        )
                    }
                }

                clientLogger.info("Making request")
                try await requestStream.executeThenClose { inboundParts, outbound in
                    try await outbound.write(.head(testRequest))
                    outbound.finish()
                    var inboundPartIterator = inboundParts.makeAsyncIterator()

                    await #expect {
                        _ = try await inboundPartIterator.next()
                    } throws: { error in
                        // When we sent a goaway from the server, 2 things happened at once: The server sent a GOAWAY on the control stream, and it sent a RESET_STREAM on the request stream.
                        // If client sees goaway first, it'll close its own stream, resulting in `rejected`.
                        // If client sees the RESET_STREAM before it sees the goaway, it'll see `remoteStreamError`.
                        // If client sees CONNECTION_CLOSE before either, it'll see `remoteConnectionError`.
                        let h3Error = error as? HTTP3Error
                        return
                            (h3Error?.code == .rejected || h3Error?.code == .remoteStreamError
                            || h3Error?.code == .remoteConnectionError)
                    }
                }

                // We should see the error fired down the pipeline
                let caughtError = try await clientRequestErrorPromise.futureResult.get()
                // When we sent a goaway from the server, 2 things happened at once: The server sent a GOAWAY on the control stream, and it sent a RESET_STREAM on the request stream.
                // If client sees goaway first, it'll close its own stream, resulting in `rejected`. Since this happened internally, there is no h3ErrorCode.
                // If client sees the RESET_STREAM before it sees the goaway, it'll see `remoteStreamError`. This will have a h3ErrorCode of rejected.
                // If client sees CONNECTION_CLOSE before either, it'll see `remoteConnectionError`.
                let h3Error = caughtError as? HTTP3Error
                #expect(
                    (h3Error?.code == .rejected && h3Error?.h3ErrorCode == nil)
                        || (h3Error?.code == .remoteStreamError && h3Error?.h3ErrorCode == .H3_REQUEST_REJECTED)
                        || (h3Error?.code == .remoteConnectionError && h3Error?.h3ErrorCode == nil)
                )

                clientLogger.info("Making another request")

                // Further request streams can't be made
                await #expect(throws: HTTP3Error.self) {
                    try await clientConnection.concurrencyView.createRequestStream {
                        $0.channel.eventLoop.makeSucceededVoidFuture()
                    }
                }

                // the client connection is closed
            }
            try await group.waitForAll()
        }

        // cleanup
        try await clientChannel.close()
    }

    // MARK: - Helper Functions

    @available(anyAppleOS 26, *)
    private func makeHTTP3Server(
        credentials: Credentials,
        settings: HTTP3Settings,
        logger: Logger,
        function: String = #function
    ) async throws -> (
        any Channel,
        HTTP3ServerConnectionMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, QUICStreamCreator>
    ) {
        switch credentials {
        case .rawKeys(let serverName, let publicKeyPath, let privateKeyPath, _):
            let quicConfiguration = QUICConfiguration.makeH3ServerConfig(
                serverName: serverName,
                publicKeyPath: publicKeyPath,
                privateKeyPath: privateKeyPath
            )
            let (channel, mux) = try await DatagramBootstrap(group: self.eventLoopGroup)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(
                    host: "127.0.0.1",
                    port: 0,
                    channelInitializer: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let mux = try channel.pipeline.syncOperations.configureHTTP3Server(
                                channel: channel,
                                settings: settings,
                                quicConfiguration: quicConfiguration,
                                logger: logger,
                                inboundRequestStreamInitializer: {
                                    let channel = $0.channel
                                    return channel.eventLoop.makeCompletedFuture {
                                        let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                            wrappingChannelSynchronously: channel,
                                            configuration: .init(isOutboundHalfClosureEnabled: true)
                                        )

                                        return asyncChannel
                                    }
                                }
                            )
                            return (channel, mux)
                        }
                    }
                )

            logger.info("QUIC server started for \(function)", metadata: ["address": "\(channel.localAddress!)"])

            return (channel, mux)
        case .certificates(_, let certPath, let keyPath, _):
            let quicConfiguration = QUICConfiguration.makeH3ServerConfig(
                certPath: certPath,
                keyPath: keyPath
            )
            let (channel, mux) = try await DatagramBootstrap(group: self.eventLoopGroup)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(
                    host: "127.0.0.1",
                    port: 0,
                    channelInitializer: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let mux = try channel.pipeline.syncOperations.configureHTTP3Server(
                                channel: channel,
                                settings: settings,
                                quicConfiguration: quicConfiguration,
                                logger: logger,
                                inboundRequestStreamInitializer: {
                                    let channel = $0.channel
                                    return channel.eventLoop.makeCompletedFuture {
                                        let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                            wrappingChannelSynchronously: channel,
                                            configuration: .init(isOutboundHalfClosureEnabled: true)
                                        )

                                        return asyncChannel
                                    }
                                }
                            )
                            return (channel, mux)
                        }
                    }
                )

            logger.info("QUIC server started for \(function)", metadata: ["address": "\(channel.localAddress!)"])

            return (channel, mux)
        }
    }

    @available(anyAppleOS 26, *)
    private func makeHTTP3Client(
        credentials: Credentials,
        settings: HTTP3Settings,
        logger: Logger
    ) async throws -> (
        any Channel, HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, NIOQUIC.QUICStreamCreator>
    ) {
        switch credentials {
        case .rawKeys(_, let publicKeyPath, _, _):
            logger.info("Starting QUIC client")

            return try await DatagramBootstrap(group: self.eventLoopGroup)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let mux = try channel.pipeline.syncOperations.configureHTTP3Client(
                            channel: channel,
                            settings: settings,
                            quicConfiguration: .makeH3ClientConfig(publicKeyPath: publicKeyPath),
                            logger: logger
                        )
                        return (channel, mux)
                    }
                }
        case .certificates(_, _, _, let trustedRootsPath):
            logger.info("Starting QUIC client")

            return try await DatagramBootstrap(group: self.eventLoopGroup)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let mux = try channel.pipeline.syncOperations.configureHTTP3Client(
                            channel: channel,
                            settings: settings,
                            quicConfiguration: .makeH3ClientConfig(trustedRootsPath: trustedRootsPath),
                            logger: logger
                        )
                        return (channel, mux)
                    }
                }
        }
    }
}
