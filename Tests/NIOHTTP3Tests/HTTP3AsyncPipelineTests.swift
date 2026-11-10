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

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOQUICHelpers
import Testing

@_spi(HTTP3AsyncInterface) @testable import NIOHTTP3

struct HTTP3AsyncPipelineTests {
    private let logger = Logger(label: "HTTP3AsyncPipelineTests")

    @available(anyAppleOS 27, *)
    @Test func serverYieldsInboundStreams() async throws {
        let connectionChannel = EmbeddedChannel()
        let connection = try self.configureServer(on: connectionChannel)
        // Activate the channel.
        try await connectionChannel.connect(to: .init(ipAddress: "127.0.0.1", port: 8000)).get()

        let requestStreamChannel = try self.receiveRequestStream(id: 0, on: connectionChannel)
        try await requestStreamChannel.close().get()
        try await connectionChannel.close().get()

        var streamIDs: [QUICStreamID] = []
        for await streamID in connection.inbound {
            streamIDs.append(streamID)
        }
        #expect(streamIDs == [QUICStreamID(rawValue: 0)])
    }

    @available(anyAppleOS 27, *)
    @Test func streamYieldFailsOnTerminatedSequence() throws {
        let connectionChannel = EmbeddedChannel()
        defer { _ = try? connectionChannel.close().wait() }

        // We drop the connection here; the underlying AsyncStream should now be in the terminated state.
        _ = try self.configureServer(on: connectionChannel)
        // Activate the channel.
        try connectionChannel.connect(to: .init(ipAddress: "127.0.0.1", port: 8000)).wait()

        // Yielding a new stream to the terminated connection stream should fail. The stream channel should therefore
        // be closed.
        let requestStreamChannel = try self.receiveRequestStream(id: 0, on: connectionChannel)
        let closed = NIOLockedValueBox(false)
        requestStreamChannel.closeFuture.whenComplete { _ in
            closed.withLockedValue { $0 = true }
        }
        connectionChannel.embeddedEventLoop.run()

        #expect(closed.withLockedValue { $0 })
    }

    @available(anyAppleOS 27, *)
    private func configureServer(on connectionChannel: EmbeddedChannel) throws -> HTTP3ServerConnection<QUICStreamID> {
        let streamCreator = try SingleChannelStreamCreator(
            mode: .server,
            eventLoop: connectionChannel.embeddedEventLoop,
            embeddedStreamChannel: EmbeddedChannel(loop: connectionChannel.embeddedEventLoop)
        )

        return try connectionChannel.pipeline.syncOperations.configureAsyncHTTP3ServerPipeline(
            streamCreator: streamCreator,
            logger: self.logger
        ) { parameters in
            parameters.channel.eventLoop.makeSucceededFuture(parameters.streamID)
        }
    }

    /// Passes a new inbound request stream with the given ID to the `HTTP3ConnectionHandler` on `connectionChannel`.
    @available(anyAppleOS 27, *)
    private func receiveRequestStream(id: UInt64, on connectionChannel: EmbeddedChannel) throws -> EmbeddedChannel {
        let streamChannel = EmbeddedChannel(loop: connectionChannel.embeddedEventLoop)
        // Set the stream ID.
        try streamChannel.syncOptions?.setOption(.quicStreamID, value: id)
        try connectionChannel.pipeline.syncOperations
            .handler(
                type: HTTP3ConnectionHandler<
                    SingleChannelStreamCreator,
                    HTTP3AsyncInboundStreamInitializer<QUICStreamID>
                >.self
            )
            .inboundStreamReceived(streamChannel)
            .wait()

        return streamChannel
    }
}
