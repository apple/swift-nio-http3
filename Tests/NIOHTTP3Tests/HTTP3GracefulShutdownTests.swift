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
import NIOExtras
import NIOQUICHelpers
import Testing

@_spi(PackageInternal) @testable import HTTP3
@testable import NIOHTTP3

struct HTTP3GracefulShutdownTests {
    private let logger = Logger(label: "HTTP3GracefulShutdownTests")

    @Test
    @available(anyAppleOS 27, *)
    func defaultDelayUsedWhenProviderNotSpecified() throws {
        let (connectionChannel, handler, _) = try self.makeServerHandler()
        defer { try? connectionChannel.close().wait() }

        #expect(handler.gracefulShutdownDelay() == .milliseconds(100))
    }

    @Test
    @available(anyAppleOS 27, *)
    func rttMultiplierUsed() throws {
        var configuration = HTTP3ServerConfiguration.defaults
        configuration.rttProvider = { .milliseconds(75) }
        configuration.gracefulShutdownRTTMultiplier = 2

        let (connectionChannel, handler, _) = try self.makeServerHandler(configuration: configuration)
        defer { try? connectionChannel.close().wait() }

        #expect(handler.gracefulShutdownDelay() == .milliseconds(150))
    }

    @Test
    @available(anyAppleOS 27, *)
    func providerIsCalledEachTime() throws {
        let callCount = NIOLockedValueBox(0)

        var configuration = HTTP3ServerConfiguration.defaults
        configuration.rttProvider = {
            callCount.withLockedValue { $0 += 1 }
            return .milliseconds(40)
        }

        let (connectionChannel, handler, _) = try self.makeServerHandler(configuration: configuration)
        defer { try? connectionChannel.close().wait() }

        _ = handler.gracefulShutdownDelay()
        _ = handler.gracefulShutdownDelay()
        _ = handler.gracefulShutdownDelay()

        #expect(callCount.withLockedValue({ $0 }) == 3)
    }

    @Test
    @available(anyAppleOS 27, *)
    func changingRTTValues() throws {
        let rttProviderReturnValue = NIOLockedValueBox<TimeAmount>(.milliseconds(50))

        var configuration = HTTP3ServerConfiguration.defaults
        configuration.rttProvider = { rttProviderReturnValue.withLockedValue { $0 } }
        configuration.gracefulShutdownRTTMultiplier = 2

        let (channel, handler, _) = try self.makeServerHandler(configuration: configuration)
        defer { try? channel.close().wait() }

        // Initial RTT.
        #expect(handler.gracefulShutdownDelay() == .milliseconds(100))

        // RTT decreases.
        rttProviderReturnValue.withLockedValue { $0 = .milliseconds(25) }
        #expect(handler.gracefulShutdownDelay() == .milliseconds(50))

        // RTT increases.
        rttProviderReturnValue.withLockedValue { $0 = .milliseconds(80) }
        #expect(handler.gracefulShutdownDelay() == .milliseconds(160))
    }

    @Test
    @available(anyAppleOS 27, *)
    func twoPhaseServerGOAWAYSequence() throws {
        var configuration = HTTP3ServerConfiguration.defaults
        configuration.rttProvider = { .milliseconds(20) }

        let (connectionChannel, handler, streamChannel) = try self.makeServerHandler(configuration: configuration)
        defer { try? connectionChannel.close().wait() }

        // Fire the connect event so the channel becomes active and the connection state machine transitions to the
        // `.initialized` case; this is required for the GOAWAY to be sent.
        let connectPromise = connectionChannel.eventLoop.makePromise(of: Void.self)
        try connectionChannel.connect(to: .init(ipAddress: "127.0.0.1", port: 8000), promise: connectPromise)
        try connectPromise.futureResult.wait()

        try handler.initiateGracefulShutdown()
        _ = try streamChannel.readOutbound(as: ByteBuffer.self)
        _ = try streamChannel.readOutbound(as: ByteBuffer.self)
        var firstGOAWAY = try #require(try streamChannel.readOutbound(as: ByteBuffer.self))

        var decoder = HTTP3FrameDecoder()
        #expect(try decoder.decode(buffer: &firstGOAWAY) == .known(.goaway(.maxServerValue)))

        // Simulate the client initiating a new stream *after* the first GOAWAY being send but *before* the second.
        let testStreamChannel = EmbeddedChannel()
        // We need to set the `QUICStreamIDChannelOption` on the channel as `HTTP3ConnectionHandler` reads this option.
        try testStreamChannel.syncOptions?.setOption(.quicStreamID, value: 0)
        try handler.inboundStreamReceived(testStreamChannel).wait()

        // Wait for the second GOAWAY to be sent.
        connectionChannel.embeddedEventLoop.advanceTime(by: .milliseconds(20))

        var secondGOAWAY = try #require(try streamChannel.readOutbound(as: ByteBuffer.self))
        #expect(try decoder.decode(buffer: &secondGOAWAY) == .known(.goaway(4)))

        // Firing the `ChannelShouldQuiesceEvent` event again should not result in graceful shutdown being initiated again.
        connectionChannel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        #expect(try streamChannel.readOutbound(as: ByteBuffer.self) == nil)
        #expect(throws: Never.self) {
            try connectionChannel.throwIfErrorCaught()
        }
    }

    @Test
    @available(anyAppleOS 27, *)
    func rejectedRequestStreamIsAbortedInBothDirections() throws {
        var configuration = HTTP3ServerConfiguration.defaults
        configuration.rttProvider = { .milliseconds(20) }

        let (connectionChannel, handler, streamChannel) = try self.makeServerHandler(configuration: configuration)
        defer { try? connectionChannel.close().wait() }

        let connectPromise = connectionChannel.eventLoop.makePromise(of: Void.self)
        try connectionChannel.connect(to: .init(ipAddress: "127.0.0.1", port: 8000), promise: connectPromise)
        try connectPromise.futureResult.wait()

        // Accept stream 0 between the two GOAWAYs, so that the second one carries ID 4.
        try handler.initiateGracefulShutdown()
        let acceptedStreamChannel = EmbeddedChannel()
        try acceptedStreamChannel.syncOptions?.setOption(.quicStreamID, value: 0)
        try handler.inboundStreamReceived(acceptedStreamChannel).wait()
        connectionChannel.embeddedEventLoop.advanceTime(by: .milliseconds(20))

        var decoder = HTTP3FrameDecoder()
        _ = try streamChannel.readOutbound(as: ByteBuffer.self)
        _ = try streamChannel.readOutbound(as: ByteBuffer.self)
        var firstGOAWAY = try #require(try streamChannel.readOutbound(as: ByteBuffer.self))
        #expect(try decoder.decode(buffer: &firstGOAWAY) == .known(.goaway(.maxServerValue)))
        var secondGOAWAY = try #require(try streamChannel.readOutbound(as: ByteBuffer.self))
        #expect(try decoder.decode(buffer: &secondGOAWAY) == .known(.goaway(4)))

        // Stream 4 is above the GOAWAY ID, so it is rejected.
        let outboundEvents = NIOLockedValueBox<[DebugOutboundEventsHandler.Event]>([])
        let rejectedStreamChannel = EmbeddedChannel(
            handler: DebugOutboundEventsHandler { event, _ in
                outboundEvents.withLockedValue { $0.append(event) }
            }
        )
        try rejectedStreamChannel.syncOptions?.setOption(.quicStreamID, value: 4)
        try rejectedStreamChannel.connect(to: .init(ipAddress: "127.0.0.1", port: 8000)).wait()
        try handler.inboundStreamReceived(rejectedStreamChannel).wait()

        let recordedOutboundEvents = outboundEvents.withLockedValue { $0 }
        let stopSendingIndex = try #require(recordedOutboundEvents.firstIndex { $0.isStopSendingEvent != nil })
        let resetStreamIndex = try #require(recordedOutboundEvents.firstIndex { $0.isResetStreamEvent != nil })
        #expect(stopSendingIndex < resetStreamIndex)
        #expect(
            recordedOutboundEvents[stopSendingIndex].isStopSendingEvent?.code
                == QUICApplicationErrorCode(.requestRejected)
        )
        #expect(
            recordedOutboundEvents[resetStreamIndex].isResetStreamEvent?.code
                == QUICApplicationErrorCode(.requestRejected)
        )

        // A rejected stream counts as open until it closes, and graceful shutdown waits for it.
        // Read the flag first: on failure, `#expect` would describe the channel, and that traps in
        // `ChannelPipeline.debugDescription`.
        let rejectedStreamIsActive = rejectedStreamChannel.isActive
        #expect(!rejectedStreamIsActive)
    }

    @Test
    @available(anyAppleOS 27, *)
    func testGOAWAYSentByClient() throws {
        let (connectionChannel, _, streamChannel) = try self.makeClientHandler(configuration: .defaults)
        defer { try? connectionChannel.close().wait() }

        // Fire the connect event so the channel becomes active and the connection state machine transitions to the
        // `.initialized` case; this is required for the GOAWAY to be sent.
        let connectPromise = connectionChannel.eventLoop.makePromise(of: Void.self)
        try connectionChannel.connect(to: .init(ipAddress: "127.0.0.1", port: 8000), promise: connectPromise)
        try connectPromise.futureResult.wait()

        // Fire the `ChannelShouldQuiesceEvent` event to initiate graceful shutdown.
        connectionChannel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        _ = try streamChannel.readOutbound(as: ByteBuffer.self)
        _ = try streamChannel.readOutbound(as: ByteBuffer.self)
        var goaway = try #require(try streamChannel.readOutbound(as: ByteBuffer.self))

        var decoder = HTTP3FrameDecoder()
        // Clients should only send one GOAWAY frame with the identifier set to 0 (we don't currently support push
        // streams).
        #expect(try decoder.decode(buffer: &goaway) == .known(.goaway(0)))

        // Firing the `ChannelShouldQuiesceEvent` event again should not result in graceful shutdown being initiated again.
        connectionChannel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        #expect(try streamChannel.readOutbound(as: ByteBuffer.self) == nil)
        #expect(throws: Never.self) {
            try connectionChannel.throwIfErrorCaught()
        }
    }

    @Test
    @available(anyAppleOS 27, *)
    func inboundRequestStreamOptsIntoHalfCloseOnStopSending() throws {
        let (connectionChannel, handler, _) = try self.makeServerHandler()
        defer { try? connectionChannel.close().wait() }

        let connectPromise = connectionChannel.eventLoop.makePromise(of: Void.self)
        try connectionChannel.connect(to: .init(ipAddress: "127.0.0.1", port: 8000), promise: connectPromise)
        try connectPromise.futureResult.wait()

        // A client's STOP_SENDING must only end the response, not the request (RFC 9000 § 3.5). By default,
        // the channel-based API of swift-nio-quic closes the whole stream.
        let requestStreamChannel = EmbeddedChannel()
        try requestStreamChannel.syncOptions?.setOption(.quicStreamID, value: 0)
        try requestStreamChannel.syncOptions?.setOption(.halfCloseOnStopSending, value: false)
        try handler.inboundStreamReceived(requestStreamChannel).wait()

        let halfCloseOnStopSending = try requestStreamChannel.syncOptions?.getOption(.halfCloseOnStopSending)
        #expect(halfCloseOnStopSending == true)
    }
}

@available(anyAppleOS 27, *)
extension HTTP3GracefulShutdownTests {
    private func makeClientHandler(
        configuration: HTTP3ClientConfiguration = .defaults
    ) throws -> (EmbeddedChannel, HTTP3ConnectionHandler<SingleChannelStreamCreator>, EmbeddedChannel) {
        let loop = EmbeddedEventLoop()
        let streamChannel = EmbeddedChannel()

        let streamCreator = try SingleChannelStreamCreator(
            mode: .client,
            eventLoop: loop,
            embeddedStreamChannel: streamChannel
        )

        let handler = HTTP3ConnectionHandler<SingleChannelStreamCreator>.client(
            eventLoop: loop,
            configuration: configuration,
            settings: HTTP3Settings(),
            streamCreator: streamCreator,
            logger: self.logger,
            inboundPushStreamInitializer: { _ in
                fatalError("Push streams are not supported")
            }
        )
        let connectionChannel = EmbeddedChannel(handler: handler, loop: loop)
        return (connectionChannel, handler, streamChannel)
    }

    private func makeServerHandler(
        configuration: HTTP3ServerConfiguration = .defaults
    ) throws -> (EmbeddedChannel, HTTP3ConnectionHandler<SingleChannelStreamCreator>, EmbeddedChannel) {
        let loop = EmbeddedEventLoop()
        let streamChannel = EmbeddedChannel()

        let streamCreator = try SingleChannelStreamCreator(
            mode: .server,
            eventLoop: loop,
            embeddedStreamChannel: streamChannel
        )

        let handler = HTTP3ConnectionHandler<SingleChannelStreamCreator>.server(
            eventLoop: loop,
            configuration: configuration,
            settings: HTTP3Settings(),
            streamCreator: streamCreator,
            logger: self.logger,
            inboundRequestStreamInitializer: { _ in loop.makeSucceededVoidFuture() }
        )
        let connectionChannel = EmbeddedChannel(handler: handler, loop: loop)
        return (connectionChannel, handler, streamChannel)
    }
}

/// A ``QUICStreamCreator`` that routes all created streams through a single ``EmbeddedChannel``.
///
/// Every call to ``createBidirectionalStream``/``createUnidirectionalStream`` invokes the stream initializer with the
/// same underlying stream channel (with a constant stream ID). This means it should only be used for tests that just
/// create a single stream.
struct SingleChannelStreamCreator: QUICStreamCreator, IsolatedQUICStreamCreator {
    let eventLoop: any EventLoop
    let embeddedStreamChannel: EmbeddedChannel

    enum Mode {
        case client
        case server
    }

    let mode: Mode

    func assumeIsolated() -> SingleChannelStreamCreator { self }

    init(mode: Mode, eventLoop: any EventLoop, embeddedStreamChannel: EmbeddedChannel) throws {
        self.mode = mode
        self.eventLoop = eventLoop
        self.embeddedStreamChannel = embeddedStreamChannel

        // Fire the connect event so the channel becomes active.
        let connectPromise = self.embeddedStreamChannel.eventLoop.makePromise(of: Void.self)
        try self.embeddedStreamChannel.connect(to: .init(ipAddress: "127.0.0.1", port: 8000), promise: connectPromise)
        try connectPromise.futureResult.wait()
    }

    /// Creates a bidirectional stream with a fixed stream ID of 0 for clients and 1 for servers.
    func createBidirectionalStream<Output: Sendable>(
        streamInitializer: @escaping (QUICStreamInitializerParameters) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        let streamID =
            switch self.mode {
            case .client:
                QUICStreamID(rawValue: 0)

            case .server:
                QUICStreamID(rawValue: 1)
            }

        return streamInitializer(
            QUICStreamInitializerParameters(channel: self.embeddedStreamChannel, streamID: streamID)
        )
    }

    /// Creates a unidirectional stream with a fixed stream ID of 2 for clients and 3 for servers.
    func createUnidirectionalStream<Output: Sendable>(
        streamInitializer: @escaping (QUICStreamInitializerParameters) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        let streamID =
            switch self.mode {
            case .client:
                QUICStreamID(rawValue: 2)

            case .server:
                QUICStreamID(rawValue: 3)
            }

        return streamInitializer(
            QUICStreamInitializerParameters(channel: self.embeddedStreamChannel, streamID: streamID)
        )
    }
}
