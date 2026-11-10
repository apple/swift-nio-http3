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

public import NIOCore
public import NIOQUICHelpers

// TODO: https://github.com/apple/swift-nio-http3/issues/1
// Allow creating outbound push streams.
/// A HTTP/3 connection from a servers side. Allows iterating inbound request streams.
@_spi(HTTP3AsyncInterface)
@available(anyAppleOS 27, *)
public struct HTTP3ServerConnection<Output: Sendable>: Sendable {
    /// An asynchronous sequence of the outputs of the stream initializer, one per inbound request stream. Finishes
    /// once the connection has become inactive.
    public let inbound: InboundStreams

    init(inbound: InboundStreams) {
        self.inbound = inbound
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
@available(anyAppleOS 27, *)
public struct HTTP3ClientConnection<
    Output: Sendable,
    StreamCreator: QUICStreamCreator & SendableMetatype
>: Sendable {
    let h3Handler: NIOLoopBound<HTTP3ConnectionHandler<StreamCreator, HTTP3InboundStreamInitializer>>

    init(
        h3Handler: NIOLoopBound<HTTP3ConnectionHandler<StreamCreator, HTTP3InboundStreamInitializer>>,
        inboundPushStreamInitializer: @Sendable (HTTP3StreamInitializerParameters) throws -> Output
    ) {
        self.h3Handler = h3Handler
    }

    /// Create a new request stream on this connection.
    /// - Parameter streamInitializer: Closure called before activation, so you can configure the Channel.
    /// - Returns: The result of the stream initializer.
    /// - Throws: If the stream cannot be created, for example because the connection has closed, or if
    ///   `streamInitializer` fails.
    public func createRequestStream<InitializerOutput: Sendable>(
        streamInitializer: @escaping @Sendable (HTTP3StreamInitializerParameters) -> EventLoopFuture<InitializerOutput>
    ) async throws -> InitializerOutput {
        try await self.h3Handler.eventLoop.flatSubmit {
            self.h3Handler.value.createRequestStream(streamInitializer: streamInitializer)
        }.get()
    }
}
