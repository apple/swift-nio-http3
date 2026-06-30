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
import Logging
public import NIOCore
public import NIOQUICHelpers

// TODO: https://github.com/apple/swift-nio-http3/issues/1
// Allow creating outbound push streams.
/// A HTTP/3 connection from a servers side. Allows iterating inbound streams.
@_spi(HTTP3AsyncInterface)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTP3ServerConnection<Output: Sendable, StreamCreator: QUICStreamCreator>: Sendable {
    /// Channel initializer called for each new inbound stream.
    private let inboundStreamInitializer: @Sendable (HTTP3StreamInitializerParameters) -> EventLoopFuture<Output>
    /// An asynchronous sequence of inbound streams.
    public let inboundStreams: InboundStreams
    /// The inboundStreams' continuation.
    private let inboundStreamsContinuation: AsyncStream<Output>.Continuation
    /// Ref to the connection handler
    private let connectionHandler: NIOLoopBoundBox<HTTP3ConnectionHandler<StreamCreator>?>

    public init(
        connectionHandler: NIOLoopBoundBox<HTTP3ConnectionHandler<StreamCreator>?>,
        inboundStreamInitializer: @escaping @Sendable (HTTP3StreamInitializerParameters) -> EventLoopFuture<Output>
    ) {
        self.inboundStreamInitializer = inboundStreamInitializer
        let (stream, continuation) = AsyncStream<Output>.makeStream()
        self.inboundStreams = .init(stream: stream)
        self.inboundStreamsContinuation = continuation
        self.connectionHandler = connectionHandler
    }

    /// Send a GOAWAY frame to the remote peer.
    /// - Throws: If the given ID is not valid, for example, if it is higher than a previously given ID.
    public func sendGoaway(id: HTTP3GoawayID) {
        _ = self.connectionHandler.eventLoop.submit {
            try self.connectionHandler.value!.sendGoaway(id: id)
        }
    }

    /// An asynchronous sequence of inbound streams.
    public struct InboundStreams: AsyncSequence, Sendable {
        public typealias Element = Output

        private let stream: AsyncStream<Output>

        init(stream: AsyncStream<Output>) {
            self.stream = stream
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: self.stream.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            private var iterator: AsyncStream<Output>.Iterator

            init(iterator: AsyncStream<Output>.Iterator) {
                self.iterator = iterator
            }

            public mutating func next() async -> Output? {
                await self.iterator.next()
            }
        }
    }
}

@available(*, unavailable)
extension HTTP3ServerConnection.InboundStreams.AsyncIterator: Sendable {}

// TODO: https://github.com/apple/swift-nio-http3/issues/1
// Allow iterating incoming push streams.
/// A HTTP/3 connection from a clients side. Allows creating outbound request streams.
@_spi(HTTP3AsyncInterface)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTP3ClientConnection<
    Output: Sendable,
    StreamCreator: QUICStreamCreator & SendableMetatype
>: Sendable {
    let h3Handler: NIOLoopBound<HTTP3ConnectionHandler<StreamCreator>>

    init(
        h3Handler: NIOLoopBound<HTTP3ConnectionHandler<StreamCreator>>,
        inboundPushStreamInitializer: @Sendable (HTTP3StreamInitializerParameters) throws -> Output
    ) {
        self.h3Handler = h3Handler
    }

    /// Create a new request stream on this connection.
    /// - Parameter streamInitializer: Closure called before activation, so you can configure the Channel.
    /// - Returns: The result of the stream initializer.
    public func createRequestStream<InitializerOutput: Sendable>(
        streamInitializer: @escaping @Sendable (HTTP3StreamInitializerParameters) -> EventLoopFuture<InitializerOutput>
    ) -> EventLoopFuture<InitializerOutput> {
        self.h3Handler.eventLoop.flatSubmit {
            self.h3Handler.value.createRequestStream(streamInitializer: streamInitializer)
        }
    }

    /// Provides an async interface for interacting with this connection.
    @_spi(HTTP3AsyncInterface)
    public struct ConcurrencyView: Sendable {
        fileprivate let underlying: HTTP3ClientConnection<Output, StreamCreator>

        /// Create a new request stream on this connection.
        /// - Parameter streamInitializer: Closure called before activation, so you can configure the Channel.
        /// - Returns: The result of the stream initializer.
        /// - Throws: If stream creation fails, or the stream initializer throws.
        public func createRequestStream<InitializerOutput: Sendable>(
            streamInitializer:
                @escaping @Sendable (HTTP3StreamInitializerParameters) -> EventLoopFuture<InitializerOutput>
        ) async throws -> InitializerOutput {
            try await self.underlying.createRequestStream(streamInitializer: streamInitializer).get()
        }
    }

    /// Provides an async interface for interacting with this connection.
    @_spi(HTTP3AsyncInterface)
    public var concurrencyView: ConcurrencyView {
        ConcurrencyView(underlying: self)
    }
}

/// Internal type to abstract away the `Output` type of the multiplexer. This means we are going through an existential
/// in the `HTTP3ConnectionHandler` when yielding a new `Channel`. However, this is okay for now otherwise
/// we would need to make the handler generic as well.
package protocol StreamMultiplexerContinuation: Sendable {
    /// We have to do a bit of an awkward dance here to carry the `Output` between the initializer and the continuation where
    /// we yield to. That's why we are using `Any` here to avoid making the handler generic.
    func initialize(parameters: HTTP3StreamInitializerParameters) -> EventLoopFuture<any Sendable>
    func yield(output: any Sendable)
    func finish()
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTP3ServerConnection: StreamMultiplexerContinuation {
    package func initialize(parameters: HTTP3StreamInitializerParameters) -> EventLoopFuture<any Sendable> {
        self.inboundStreamInitializer(parameters).map { $0 as any Sendable }
    }

    package func yield(output: any Sendable) {
        self.inboundStreamsContinuation.yield(output as! Output)
    }

    package func finish() {
        self.inboundStreamsContinuation.finish()
    }
}

/// Allows you to iterate incoming connections from clients.
///
/// You can use this type to wrap a QUIC implementation. Have the QUIC implementation call ``yield(connection:)`` and ``finish()`` as appropriate.
/// Then, you can easily iterate through incoming connections and handle them.
@_spi(HTTP3AsyncInterface)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTP3ServerConnectionMultiplexer<Output: Sendable, StreamCreator: QUICStreamCreator>: Sendable {
    /// The inboundConnections' continuation.
    private let inboundConnectionsContinuation: AsyncStream<HTTP3ServerConnection<Output, StreamCreator>>.Continuation
    /// An asynchronous sequence of inbound connections.
    public let inboundConnections: InboundConnections

    /// Create a new ``HTTP3ServerConnectionMultiplexer``.
    public init() {
        let (stream, continuation) = AsyncStream<HTTP3ServerConnection<Output, StreamCreator>>.makeStream()
        self.inboundConnections = .init(stream: stream)
        self.inboundConnectionsContinuation = continuation
    }

    /// An asynchronous sequence of inbound connections. Use this to consume incoming connections.
    public struct InboundConnections: AsyncSequence, Sendable {
        public typealias Element = HTTP3ServerConnection<Output, StreamCreator>

        private let stream: AsyncStream<HTTP3ServerConnection<Output, StreamCreator>>

        init(stream: AsyncStream<HTTP3ServerConnection<Output, StreamCreator>>) {
            self.stream = stream
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: self.stream.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            private var iterator: AsyncStream<HTTP3ServerConnection<Output, StreamCreator>>.Iterator

            init(iterator: AsyncStream<HTTP3ServerConnection<Output, StreamCreator>>.Iterator) {
                self.iterator = iterator
            }

            public mutating func next() async -> HTTP3ServerConnection<Output, StreamCreator>? {
                await self.iterator.next()
            }
        }
    }

    /// Call this function with the connection channel whenever a new connection comes in.
    public func yield(connection: HTTP3ServerConnection<Output, StreamCreator>) {
        self.inboundConnectionsContinuation.yield(connection)
    }

    /// Call this function when there are no more incoming connections.
    public func finish() {
        self.inboundConnectionsContinuation.finish()
    }
}

@available(*, unavailable)
extension HTTP3ServerConnectionMultiplexer.InboundConnections.AsyncIterator: Sendable {}

/// Implementations of QUIC should implement this protocol to be able to use the HTTP3ClientConnectionMultiplexer.
@_spi(HTTP3AsyncInterface)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol HTTP3ConnectionCreator {
    /// Create a new QUIC connection using the parameters provided.
    /// - Parameters:
    ///   - serverName: Name of the remote server to connect to.
    ///   - remoteAddress: Address of the remote server to connect to.
    ///   - connectionInitializer: Closure to run before activating the new channel.
    /// - Returns: The new channel.
    func createNewConnection(
        serverName: String,
        remoteAddress: SocketAddress,
        connectionInitializer: @Sendable @escaping (any Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<any Channel>
}

/// Allows you to create outbound connections as a client.
@_spi(HTTP3AsyncInterface)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTP3ClientConnectionMultiplexer<
    ConnectionCreator: HTTP3ConnectionCreator & SendableMetatype,
    StreamCreator: QUICStreamCreator
>: Sendable {
    /// The event loop.
    private let eventLoop: any EventLoop
    /// A method to create a new connection. This should return a new channel, and should add the HTTP3ConnectionHandler to that channel.
    internal let _createNewConnection: NIOLoopBound<ConnectionCreator>

    public init(
        eventLoop: any EventLoop,
        createNewConnection: NIOLoopBound<ConnectionCreator>
    ) {
        self.eventLoop = eventLoop
        self._createNewConnection = createNewConnection
    }

    /// Create an outbound connection.
    /// - Parameters:
    ///   - serverName: The server to connect to.
    ///   - remoteAddress: The address to connect to.
    ///   - inboundPushStreamInitializer: Called for each incoming push stream.
    /// - Returns: A future of a ``HTTP3ClientConnection`` which can be used to create outbound requests and receive inbound pushs.
    public func createConnection<Output>(
        serverName: String,
        remoteAddress: SocketAddress,
        inboundPushStreamInitializer: @Sendable @escaping (HTTP3StreamInitializerParameters) throws -> Output
    ) -> EventLoopFuture<HTTP3ClientConnection<Output, StreamCreator>> {
        self.createConnection(
            serverName: serverName,
            remoteAddress: remoteAddress,
            connectionInitializer: nil,
            inboundPushStreamInitializer: inboundPushStreamInitializer
        ).map { $0.0 }
    }

    /// Create an outbound connection.
    /// - Parameters:
    ///   - serverName: The server to connect to.
    ///   - remoteAddress: The address to connect to.
    ///   - connectionInitializer: Use this to add handlers to the outgoing connection channel.
    ///   - inboundPushStreamInitializer: Called for each incoming push stream.
    /// - Returns: The future containing the result of the connection initializer, and the underlying connection channel.
    package func createConnection<Output>(
        serverName: String,
        remoteAddress: SocketAddress,
        connectionInitializer: (@Sendable (any Channel) -> EventLoopFuture<Void>)?,
        inboundPushStreamInitializer: @Sendable @escaping (HTTP3StreamInitializerParameters) throws -> Output
    ) -> EventLoopFuture<(HTTP3ClientConnection<Output, StreamCreator>, any Channel)> {
        self.createConnectionChannel(
            serverName: serverName,
            remoteAddress: remoteAddress,
            connectionInitializer: connectionInitializer
        ).flatMapThrowing { channel in
            let h3Handler = try channel.pipeline.syncOperations.handler(
                type: HTTP3ConnectionHandler<StreamCreator>.self
            )
            let h3HandlerBox = NIOLoopBound(h3Handler, eventLoop: self.eventLoop)
            let connection = HTTP3ClientConnection(
                h3Handler: h3HandlerBox,
                inboundPushStreamInitializer: inboundPushStreamInitializer
            )
            return (connection, channel)
        }
    }

    package func createConnectionChannel(
        serverName: String,
        remoteAddress: SocketAddress,
        connectionInitializer: (@Sendable (any Channel) -> EventLoopFuture<Void>)?
    ) -> EventLoopFuture<any Channel> {
        self.eventLoop.flatSubmit {
            self._createNewConnection.value.createNewConnection(
                serverName: serverName,
                remoteAddress: remoteAddress,
                connectionInitializer: connectionInitializer ?? { $0.eventLoop.makeSucceededVoidFuture() }
            )
        }
    }

    /// Provides an async interface for interacting with this multiplexer.
    public struct ConcurrencyView: Sendable {
        fileprivate let underlying: HTTP3ClientConnectionMultiplexer<ConnectionCreator, StreamCreator>
        /// Create an outbound connection.
        /// - Parameters:
        ///   - serverName: The server to connect to.
        ///   - remoteAddress: The address to connect to.
        ///   - inboundPushStreamInitializer: Called for each incoming push stream.
        /// - Returns: A ``HTTP3ClientConnection`` which can be used to create outbound requests and receive inbound pushes.
        /// - Throws: If failed to create new connection.
        @_spi(HTTP3AsyncInterface)
        public func createConnection<Output>(
            serverName: String,
            remoteAddress: SocketAddress,
            inboundPushStreamInitializer: @Sendable @escaping (HTTP3StreamInitializerParameters) throws -> Output
        ) async throws -> HTTP3ClientConnection<Output, StreamCreator> {
            try await self.underlying.createConnection(
                serverName: serverName,
                remoteAddress: remoteAddress,
                inboundPushStreamInitializer: inboundPushStreamInitializer
            ).get()
        }
    }

    /// Provides an async interface for interacting with this multiplexer.
    public var concurrencyView: ConcurrencyView {
        ConcurrencyView(underlying: self)
    }
}
