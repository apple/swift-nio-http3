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
import NIOConcurrencyHelpers
import NIOCore
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOHTTPTypes
import NIOPosix
import NIOQUIC
import NIOQUICHelpers
import QPACK
import Testing
import X509

/// Buffers incoming body data until end. Then echoes it all back with a 200 status header.
final class EchoHTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPRequestPart
    typealias OutboundOut = HTTPResponsePart

    private var receivedData = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head: break
        case .body(let body):
            self.receivedData.writeImmutableBuffer(body)
        case .end:
            context.write(self.wrapOutboundOut(.head(.init(status: .ok))), promise: nil)
            context.write(self.wrapOutboundOut(.body(self.receivedData)), promise: nil)
            context.write(self.wrapOutboundOut(.end()), promise: nil)
        }
        context.fireChannelRead(data)
    }
}

/// Whenever something comes in, holds on to it for some time before firing. Can be used to force one stream to be slower, to find races.
final class InboundSlowingHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let delay: TimeAmount

    init(delay: TimeAmount) {
        self.delay = delay
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.eventLoop.assumeIsolated().scheduleTask(in: self.delay) {
            context.fireChannelRead(data)
        }
    }
}

final class InboundDataRecorder<DataType: Sendable>: ChannelInboundHandler {
    typealias InboundIn = DataType
    typealias InboundOut = DataType

    enum Error: Swift.Error {
        case countNotMet
    }

    private var data: [DataType] = []

    private let promise: EventLoopPromise<[DataType]>
    private let targetCount: Int

    init(promise: EventLoopPromise<[DataType]>, targetCount: Int) {
        self.promise = promise
        self.targetCount = targetCount
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.promise.fail(Error.countNotMet)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let typed = unwrapInboundIn(data)
        self.data.append(typed)
        if self.data.count == self.targetCount {
            self.promise.succeed(self.data)
        }
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Swift.Error) {
        self.promise.fail(error)
    }
}

/// Server handler that waits for external signal before responding.
/// Uses two promises for control: one signals when request is received,
/// another controls when response is sent.
/// Request number `immediateResponseCount + 1` waits for signal; all others respond immediately.
private final class ControllableEchoResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPRequestPart
    typealias OutboundOut = HTTPResponsePart

    private let requestReceivedSignal: EventLoopPromise<Void>
    private let responseSignal: EventLoopPromise<Void>
    private let responseToSend: HTTPResponse
    private let immediateResponseCount: Int
    private let requestCounter: NIOLockedValueBox<Int>
    private var receivedData = ByteBuffer()

    init(
        requestReceivedSignal: EventLoopPromise<Void>,
        responseSignal: EventLoopPromise<Void>,
        responseToSend: HTTPResponse,
        immediateResponseCount: Int,
        requestCounter: NIOLockedValueBox<Int>
    ) {
        self.requestReceivedSignal = requestReceivedSignal
        self.responseSignal = responseSignal
        self.responseToSend = responseToSend
        self.immediateResponseCount = immediateResponseCount
        self.requestCounter = requestCounter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)

        switch part {
        case .head:
            break
        case .body(let body):
            self.receivedData.writeImmutableBuffer(body)
        case .end:
            let requestNum = self.requestCounter.withLockedValue { requestCounter in
                requestCounter += 1
                return requestCounter
            }

            let responseData = self.receivedData
            self.receivedData.clear()

            if requestNum == self.immediateResponseCount + 1 {
                // This is the request we want to control - signal and wait
                self.requestReceivedSignal.succeed()

                self.responseSignal.futureResult
                    .hop(to: context.eventLoop)
                    .assumeIsolated()
                    .whenComplete { _ in
                        self.sendResponse(context: context, body: responseData)
                    }
            } else {
                self.sendResponse(context: context, body: responseData)
            }
        }

        context.fireChannelRead(data)
    }

    private func sendResponse(context: ChannelHandlerContext, body: ByteBuffer) {
        context.write(self.wrapOutboundOut(.head(self.responseToSend)), promise: nil)
        context.write(self.wrapOutboundOut(.body(body)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end()), promise: nil)
    }
}

/// Closes immediately after activation
private final class SelfClosingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Never
    typealias OutboundIn = Never

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        context.close(promise: nil)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            context.close(promise: nil)
        }
    }
}

/// Sends a `STOP_SENDING` immediately after activation.
private final class RequestStopSendingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Never
    typealias OutboundIn = Never

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        context.triggerUserOutboundEvent(QUICStopSendingEvent(code: QUICApplicationErrorCode(0)!), promise: nil)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            context.triggerUserOutboundEvent(QUICStopSendingEvent(code: QUICApplicationErrorCode(0)!), promise: nil)
        }
    }
}

/// We fail promises with this error when they are about to be dropped.
/// This prevents hitting an assertion in the implementation of promise.
struct NeverFulfilled: Error {}

struct EndToEndTests {
    private let eventLoopGroup = MultiThreadedEventLoopGroup.singleton

    private static let standardAuthenticationConfigurations: [AuthenticationConfiguration] = {
        [.keys, .certs]
    }()

    @Test(arguments: Self.standardAuthenticationConfigurations)
    @available(anyAppleOS 26, *)
    func testSettingsFrame(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        // These settings are arbitrary, just so we can test whether they come through to the other side
        let clientSettings = try HTTP3Settings(parsing: [.init(identifier: .init(extensionSetting: 10001)!, value: 10)])
        let serverSettings = try HTTP3Settings(parsing: [.init(identifier: .init(extensionSetting: 10002)!, value: 20)])

        let serverControlStreamFramesPromise = self.eventLoopGroup.any().makePromise(of: [HTTP3Frame].self)
        let clientControlStreamFramesPromise = self.eventLoopGroup.any().makePromise(of: [HTTP3Frame].self)

        defer {
            serverControlStreamFramesPromise.fail(NeverFulfilled())
            clientControlStreamFramesPromise.fail(NeverFulfilled())
        }

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: serverSettings,
            logger: serverLogger,
            inboundStreamInitializer: {
                // This is important. Although there is a control stream, that shouldn't be visible to us here
                Issue.record("Unexpected inbound stream with ID \($0.streamID)")
                return $0.channel.eventLoop.makeSucceededVoidFuture()
            },
            internalInboundStreamInitializer: { channel, _, streamType in
                switch streamType {
                case .control:
                    return channel.eventLoop.makeCompletedFuture {
                        let recorder = InboundDataRecorder(promise: serverControlStreamFramesPromise, targetCount: 1)
                        try channel.pipeline.syncOperations.addHandler(recorder)
                    }
                default:
                    // We don't care about this stream
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: clientSettings,
            logger: clientLogger,
            internalInboundStreamInitializer: { streamChannel, _, streamType in
                switch streamType {
                case .control:
                    return streamChannel.eventLoop.makeCompletedFuture {
                        let recorder = InboundDataRecorder(promise: clientControlStreamFramesPromise, targetCount: 1)
                        try streamChannel.pipeline.syncOperations.addHandler(recorder)
                    }
                default:
                    // We don't care about this stream
                    return streamChannel.eventLoop.makeSucceededVoidFuture()
                }
            }
        )

        // Assert that the client and server get each others settings
        let serverReceivedControlFrames = try await serverControlStreamFramesPromise.futureResult.get()
        let clientReceivedControlFrames = try await clientControlStreamFramesPromise.futureResult.get()
        #expect(serverReceivedControlFrames == [.settings(clientSettings)])
        #expect(clientReceivedControlFrames == [.settings(serverSettings)])

        // Tear down
        try await serverChannel.pipeline.handler(type: QUICHandler.self).flatMap {
            $0.shutdownGracefully(deadline: .now())
        }.get()
        try await clientConnectionChannel.closeFuture.get()
    }

    // This test enables the dynamic table on both sides, but adds a handler which causes QPACK instructions to be delayed.
    // This test will currently fail, because the clients stream channel will close before the instructions arrive for decoding the response headers.
    // This problem, and potential solutions, are explored in the `DynamicTable` document in the `NIOHTTP3` module.
    @Test(
        .disabled("See DynamicTable document in NIOHTTP3 module"),
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testRoundtripWithSlowDynamicTable(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let clientReceivedFramesPromise = self.eventLoopGroup.any().makePromise(of: [HTTP3Frame].self)
        let serverReceivedFramesPromise = self.eventLoopGroup.any().makePromise(of: [HTTP3Frame].self)
        let serverReceivedQpackEncoderInstructionsPromise = self.eventLoopGroup.any().makePromise(
            of: [QPACKEncoderInstruction].self
        )
        let clientReceivedQpackEncoderInstructionsPromise = self.eventLoopGroup.any().makePromise(
            of: [QPACKEncoderInstruction].self
        )
        let serverReceivedQpackDecoderInstructionsPromise = self.eventLoopGroup.any().makePromise(
            of: [QPACKDecoderInstruction].self
        )
        let clientReceivedQpackDecoderInstructionsPromise = self.eventLoopGroup.any().makePromise(
            of: [QPACKDecoderInstruction].self
        )
        let serverReceivedEncoderInstructionStream = self.eventLoopGroup.any().makePromise(of: Void.self)
        let clientReceivedEncoderInstructionStream = self.eventLoopGroup.any().makePromise(of: Void.self)

        defer {
            clientReceivedFramesPromise.fail(NeverFulfilled())
            serverReceivedFramesPromise.fail(NeverFulfilled())
            serverReceivedQpackEncoderInstructionsPromise.fail(NeverFulfilled())
            clientReceivedQpackEncoderInstructionsPromise.fail(NeverFulfilled())
            serverReceivedQpackDecoderInstructionsPromise.fail(NeverFulfilled())
            clientReceivedQpackDecoderInstructionsPromise.fail(NeverFulfilled())
            serverReceivedEncoderInstructionStream.fail(NeverFulfilled())
            clientReceivedEncoderInstructionStream.fail(NeverFulfilled())
        }

        let settings: HTTP3Settings = .forTestingWithDynamicTable

        final class TestServerHandler: ChannelInboundHandler {
            typealias InboundIn = HTTP3Frame
            typealias OutboundOut = HTTP3Frame

            init() {}

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let fields: [HTTPField] = [
                    .init(name: .status, value: "200"),
                    .init(name: .init("test")!, value: "hello"),
                ]
                context.writeAndFlush(self.wrapOutboundOut(.headers(fields)), promise: nil)
                context.close(mode: .output, promise: nil)
            }
        }

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: settings,
            logger: serverLogger,
            inboundStreamInitializer: {
                // Only the one request stream should be visible here
                #expect($0.streamID.isBidirectional)
                #expect($0.streamID.isClientInitiated)
                let serverRecorder = InboundDataRecorder(
                    promise: serverReceivedFramesPromise,
                    targetCount: 1
                )
                let channel = $0.channel
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(serverRecorder)
                    try channel.pipeline.syncOperations.addHandler(TestServerHandler())
                }
            },
            internalInboundStreamInitializer: { streamChannel, _, streamType in
                streamChannel.eventLoop.makeCompletedFuture {
                    switch streamType {
                    case .qpackEncoder:
                        let recorder = InboundDataRecorder(
                            promise: serverReceivedQpackEncoderInstructionsPromise,
                            targetCount: 3
                        )
                        try streamChannel.pipeline.syncOperations.addHandler(recorder)
                        serverReceivedEncoderInstructionStream.succeed()
                    case .qpackDecoder:
                        let recorder = InboundDataRecorder(
                            promise: serverReceivedQpackDecoderInstructionsPromise,
                            targetCount: 1
                        )
                        try streamChannel.pipeline.syncOperations.addHandler(recorder)
                    case .control:
                        break  // not interested in the control stream for this test
                    default: Issue.record("Not expecting any other streams")
                    }
                }
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: settings,
            logger: clientLogger,
            internalInboundStreamInitializer: { streamChannel, _, streamType in
                streamChannel.eventLoop.makeCompletedFuture {
                    switch streamType {
                    case .qpackDecoder:
                        let recorder = InboundDataRecorder(
                            promise: clientReceivedQpackDecoderInstructionsPromise,
                            targetCount: 1
                        )
                        try streamChannel.pipeline.syncOperations.addHandler(recorder)
                    case .qpackEncoder:
                        try streamChannel.pipeline.syncOperations.addHandler(
                            InboundSlowingHandler(delay: .milliseconds(500)),
                            position: .first
                        )
                        let recorder = InboundDataRecorder(
                            promise: clientReceivedQpackEncoderInstructionsPromise,
                            targetCount: 2
                        )
                        try streamChannel.pipeline.syncOperations.addHandler(recorder)
                        clientReceivedEncoderInstructionStream.succeed()
                    case .control:
                        break  // not interested in the control stream for this test
                    default: Issue.record("Not expecting any other streams")
                    }
                }
            }
        )

        let requestStreamChannel = try await clientConnectionChannel.makeHTTP3RequestChannel {
            let clientRecorder = InboundDataRecorder(promise: clientReceivedFramesPromise, targetCount: 1)
            try $0.channel.pipeline.syncOperations.addHandler(clientRecorder)
        }.get()

        // Wait for qpack dynamic table to be initialized. This happens when both sides have received the encoder instruction stream.
        // After that point, both sides are able to create dynamic table entries and send them over that stream.
        try await serverReceivedEncoderInstructionStream.futureResult.get()
        try await clientReceivedEncoderInstructionStream.futureResult.get()

        let frame = HTTP3Frame.headers(
            [
                .init(name: .method, value: "GET"),
                .init(name: .path, value: "/"),
                .init(name: .scheme, value: "https"),
                .init(name: .authority, value: "test"),
                .init(name: .userAgent, value: "test-agent"),
            ]
        )

        try await requestStreamChannel.writeAndFlush(frame)
        requestStreamChannel.close(mode: .output, promise: nil)

        try await requestStreamChannel.closeFuture.get()

        let serverReceivedFrames = try await serverReceivedFramesPromise.futureResult.get()
        let clientReceivedFrames = try await clientReceivedFramesPromise.futureResult.get()

        #expect(serverReceivedFrames == [frame])
        #expect(
            clientReceivedFrames == [
                .headers([.init(name: .status, value: "200"), .init(name: .init("test")!, value: "hello")])
            ]
        )

        // Make sure it used the dynamic table as expected

        // Server should have received the dynamic table capacity + the 2 headers the client sent
        let serverReceivedEncoderInstructions = try await serverReceivedQpackEncoderInstructionsPromise.futureResult
            .get()
        try #require(serverReceivedEncoderInstructions.count == 3)
        #expect(serverReceivedEncoderInstructions[0] == .setDynamicTableCapacity(1024))
        #expect(
            serverReceivedEncoderInstructions[1]
                == .insertWithNameReference(.staticTable, relativeIndex: 0, value: "test")
        )
        #expect(
            serverReceivedEncoderInstructions[2]
                == .insertWithNameReference(.staticTable, relativeIndex: 95, value: "test-agent")
        )

        // Client receives an ack for those
        let clientReceivedDecoderInstructions = try await clientReceivedQpackDecoderInstructionsPromise.futureResult
            .get()
        try #require(clientReceivedDecoderInstructions.count == 1)
        #expect(
            clientReceivedDecoderInstructions.first == QPACKDecoderInstruction.insertCountIncrement(increment: 1)
        )

        // client should have received the dynamic table capacity + the 1 header the server sent
        let clientReceivedEncoderInstructions = try await clientReceivedQpackEncoderInstructionsPromise.futureResult
            .get()
        try #require(clientReceivedEncoderInstructions.count == 2)
        #expect(clientReceivedEncoderInstructions[0] == .setDynamicTableCapacity(1024))
        #expect(
            clientReceivedEncoderInstructions[1]
                == .insertWithLiteralName(name: "test", value: "hello")
        )

        // server receives an ack for those
        let serverReceivedDecoderInstructions = try await serverReceivedQpackDecoderInstructionsPromise.futureResult
            .get()
        try #require(serverReceivedDecoderInstructions.count == 1)
        #expect(
            serverReceivedDecoderInstructions.first == QPACKDecoderInstruction.insertCountIncrement(increment: 1)
        )

        // Tear down
        try await serverChannel.pipeline.handler(type: QUICHandler.self).flatMap {
            $0.shutdownGracefully(deadline: .now())
        }.get()
        try await clientConnectionChannel.closeFuture.get()
    }

    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testRoundtripWithoutDynamicTable(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let clientReceivedFramesPromise = self.eventLoopGroup.any().makePromise(of: [HTTP3Frame].self)
        let serverReceivedFramesPromise = self.eventLoopGroup.any().makePromise(of: [HTTP3Frame].self)

        defer {
            clientReceivedFramesPromise.fail(NeverFulfilled())
            serverReceivedFramesPromise.fail(NeverFulfilled())
        }

        let settings = HTTP3Settings()  // No qpack

        final class TestServerHandler: ChannelInboundHandler {
            typealias InboundIn = HTTP3Frame
            typealias OutboundOut = HTTP3Frame

            init() {}

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.writeAndFlush(
                    self.wrapOutboundOut(.headers([.init(name: .status, value: "200")])),
                    promise: nil
                )
                context.close(mode: .output, promise: nil)
            }
        }

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: settings,
            logger: serverLogger,
            inboundStreamInitializer: {
                // Only the one request stream should be visible here
                #expect($0.streamID.isBidirectional)
                #expect($0.streamID.isClientInitiated)
                let serverRecorder = InboundDataRecorder(promise: serverReceivedFramesPromise, targetCount: 1)
                let channel = $0.channel
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(serverRecorder)
                    try channel.pipeline.syncOperations.addHandler(TestServerHandler())
                }
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: settings,
            logger: clientLogger,
            internalInboundStreamInitializer: { channel, _, streamType in
                switch streamType {
                case .control:
                    break  // not interested in the control stream for this test
                default: Issue.record("Not expecting any other streams")
                }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )

        let requestStreamChannel = try await clientConnectionChannel.makeHTTP3RequestChannel {
            let clientRecorder = InboundDataRecorder(promise: clientReceivedFramesPromise, targetCount: 1)
            try $0.channel.pipeline.syncOperations.addHandler(clientRecorder)
        }.get()

        let frame = HTTP3Frame.headers(
            [
                .init(name: .method, value: "GET"),
                .init(name: .path, value: "/"),
                .init(name: .scheme, value: "https"),
                .init(name: .authority, value: "test"),
                .init(name: .userAgent, value: "test-agent"),
            ]
        )
        try await requestStreamChannel.writeAndFlush(frame)
        requestStreamChannel.close(mode: .output, promise: nil)

        // After server sends response, stream should self-close
        try await requestStreamChannel.closeFuture.get()

        // Make sure server saw request and client saw response
        let serverReceivedFrames = try await serverReceivedFramesPromise.futureResult.get()
        let clientReceivedFrames = try await clientReceivedFramesPromise.futureResult.get()
        #expect(serverReceivedFrames == [frame])
        #expect(clientReceivedFrames == [.headers([HTTPField(name: .status, value: "200")])])

        // Tear down
        try await serverChannel.pipeline.handler(type: QUICHandler.self).flatMap {
            $0.shutdownGracefully(deadline: .now())
        }.get()
        try await clientConnectionChannel.closeFuture.get()
    }

    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testConnectionError(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let clientErrorPromise = self.eventLoopGroup.any().makePromise(of: (any Error).self)

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger,
            connectionInitializer: { channel in
                channel.pipeline.addHandler(ErrorCatchingHandler(errorPromise: clientErrorPromise))
            }
        )

        let requestStreamChannel = try await clientConnectionChannel.makeHTTP3RequestChannel().get()

        // Write a settings frame, which is illegal on the request stream
        // Our outbound handlers will prevent writing an invalid frame, so we need to skip past the stream handler
        _ = requestStreamChannel.eventLoop.submit {
            let streamHandler = try requestStreamChannel.pipeline.syncOperations.handler(type: HTTP3StreamHandler.self)
            let streamHandlerContext = try requestStreamChannel.pipeline.syncOperations.context(handler: streamHandler)
            var buffer = ByteBuffer()
            buffer.writeHTTP3PartialFrame(.settings(HTTP3Settings()), preferHuffmanEncoding: false)
            streamHandlerContext.writeAndFlush(NIOAny(buffer), promise: nil)
        }

        let clientConnectionError = try await clientErrorPromise.futureResult.get()
        let clientH3ConnectionError = clientConnectionError as? HTTP3Error
        #expect(clientH3ConnectionError?.code == .remoteConnectionError)
        #expect(clientH3ConnectionError?.h3ErrorCode == .frameUnexpected)
        #expect(clientH3ConnectionError?.message == "Expected headers, got settings")

        // Client connection should close itself
        try await clientConnectionChannel.closeFuture.get()
        try await serverChannel.close()
    }

    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testServerClosesConnection(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let clientErrorPromise = self.eventLoopGroup.any().makePromise(of: (any Error).self)

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger,
            inboundConnectionInitializer: { channel in
                // we want to immediately force-close all incoming connections
                channel.pipeline.addHandler(SelfClosingHandler())
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger,
            connectionInitializer: { channel in
                channel.pipeline.addHandler(ErrorCatchingHandler(errorPromise: clientErrorPromise))
            }
        )

        let clientConnectionError = try await clientErrorPromise.futureResult.get()
        let clientH3ConnectionError = clientConnectionError as? HTTP3Error
        #expect(clientH3ConnectionError?.code == .remoteConnectionError)
        #expect(clientH3ConnectionError?.h3ErrorCode == .noError)

        // Client connection should close itself
        try await clientConnectionChannel.closeFuture.get()
        try await serverChannel.close()
    }

    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testClosingConnectionAlsoClosesStreams(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let lastServerConnection: NIOLockedValueBox<(any Channel)?> = .init(nil)

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger,
            inboundConnectionInitializer: { conn in
                lastServerConnection.withLockedValue { $0 = conn }
                return conn.eventLoop.makeSucceededVoidFuture()
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger
        )

        let requestStreamChannel = try await clientConnectionChannel.makeHTTP3RequestChannel().get()

        // Close the client connection
        try await clientConnectionChannel.close()

        // request stream channel should close
        try await requestStreamChannel.closeFuture.get()

        // Client connection should close
        try await clientConnectionChannel.closeFuture.get()

        // server connection should close itself
        let serverConnection = lastServerConnection.withLockedValue { $0 }
        try #require(serverConnection != nil)
        try await serverConnection!.closeFuture.get()

        // Cleanup: close the whole server
        try await serverChannel.close()
    }

    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testServerClosesConnectionWithActiveStream(
        authenticationConfiguration: AuthenticationConfiguration
    ) async throws {
        // When the server closes the connection while the client has a request stream open,
        // the client's request stream should see an error rather than a clean close.
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let streamErrorPromise = self.eventLoopGroup.any().makePromise(of: (any Error).self)
        defer { streamErrorPromise.fail(NeverFulfilled()) }

        let lastServerConnection: NIOLockedValueBox<(any Channel)?> = .init(nil)

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger,
            inboundConnectionInitializer: { conn in
                lastServerConnection.withLockedValue { $0 = conn }
                return conn.eventLoop.makeSucceededVoidFuture()
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger
        )

        // Create a request stream with an error catcher
        let requestStreamChannel = try await clientConnectionChannel.makeHTTP3RequestChannel {
            try $0.channel.pipeline.syncOperations.addHandler(
                ErrorCatchingHandler(errorPromise: streamErrorPromise)
            )
        }.get()

        // Now close the server connection while the request stream is open
        let serverConnection = try #require(lastServerConnection.withLockedValue { $0 })
        try await serverConnection.close()

        // The request stream should see an error, not a clean close
        let streamError = try await streamErrorPromise.futureResult.get()
        let h3Error = streamError as? HTTP3Error
        #expect(h3Error?.code == .remoteConnectionError)

        // Request stream should close
        try await requestStreamChannel.closeFuture.get()

        // Client connection should close
        try await clientConnectionChannel.closeFuture.get()

        // Cleanup
        try await serverChannel.close()
    }

    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testStreamError(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let clientErrorPromise = self.eventLoopGroup.any().makePromise(of: (any Error).self)

        defer {
            clientErrorPromise.fail(NeverFulfilled())
        }

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger
        )

        let requestStreamChannel = try await clientConnectionChannel.makeHTTP3RequestChannel {
            try $0.channel.pipeline.syncOperations.addHandler(ErrorCatchingHandler(errorPromise: clientErrorPromise))
        }.get()

        // Write a malformed header, which can't decode.
        // Our outbound handlers will prevent writing an invalid frame, so we need to skip past the stream handler.
        _ = requestStreamChannel.eventLoop.submit {
            let streamHandler = try requestStreamChannel.pipeline.syncOperations.handler(type: HTTP3StreamHandler.self)
            let streamHandlerContext = try requestStreamChannel.pipeline.syncOperations.context(handler: streamHandler)
            var buffer = ByteBuffer()
            buffer.writeHTTP3PartialFrame(
                .headers(
                    .init(
                        fieldSection: .init(
                            prefix: .init(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
                            // Uppercase field names are illegal
                            lines: [.literal(requireLiteralRepresentation: false, name: "A", value: "B")]
                        )
                    )
                ),
                preferHuffmanEncoding: false
            )
            streamHandlerContext.writeAndFlush(NIOAny(buffer), promise: nil)
        }

        let streamError = try await clientErrorPromise.futureResult.get()
        let clientH3ConnectionError = streamError as? HTTP3Error
        #expect(clientH3ConnectionError?.code == .remoteStreamError)
        #expect(clientH3ConnectionError?.h3ErrorCode == .messageError)

        // Request stream should close because of the error
        try await requestStreamChannel.closeFuture.get()

        try await serverChannel.close()
        try await clientConnectionChannel.close()
    }

    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testUnknownIncomingStream(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let clientErrorPromise = self.eventLoopGroup.any().makePromise(of: (any Error).self)

        defer {
            clientErrorPromise.fail(NeverFulfilled())
        }

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger
        )

        let streamChannel = try await clientConnectionChannel.makeHTTP3UnidirectionalStreamChannel(
            streamType: .unknown(raw: 101)
        ) {
            try $0.channel.pipeline.syncOperations.addHandler(ErrorCatchingHandler(errorPromise: clientErrorPromise))
        }.get()

        // Write any random bytes into this stream. The other end should never read them anyway (because data in streams of unknown types should be dropped)
        _ = streamChannel.eventLoop.submit {
            streamChannel.writeAndFlush(ByteBuffer(string: "hello"), promise: nil)
        }

        let clientStreamError = try await clientErrorPromise.futureResult.get()
        let clientStreamQUICError = clientStreamError as? QUICStopSendingError
        #expect(clientStreamQUICError?.code == QUICApplicationErrorCode(.streamCreationError))

        // Client stream should close
        try await streamChannel.closeFuture.get()

        // Cleanup
        try await serverChannel.close()
    }

    // This is always an error; clients must not open push streams to servers.
    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testIncomingPushStreamOnServer(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let clientErrorPromise = self.eventLoopGroup.any().makePromise(of: (any Error).self)

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger,
            connectionInitializer: { channel in
                channel.pipeline.addHandler(ErrorCatchingHandler(errorPromise: clientErrorPromise))
            }
        )

        let pushStreamChannel = try await clientConnectionChannel.makeHTTP3UnidirectionalStreamChannel(
            streamType: .push
        ).get()

        // Write the push id on the push stream
        _ = try await pushStreamChannel.eventLoop.submit {
            var buffer = ByteBuffer()
            buffer.writeEncodedInteger(10, strategy: .quic)
            pushStreamChannel.writeAndFlush(buffer, promise: nil)
        }.get()

        let clientConnectionError = try await clientErrorPromise.futureResult.get()
        let clientH3ConnectionError = clientConnectionError as? HTTP3Error
        #expect(clientH3ConnectionError?.code == .remoteConnectionError)
        #expect(clientH3ConnectionError?.h3ErrorCode == .streamCreationError)
        #expect(clientH3ConnectionError?.message == "Cannot accept push stream on server")

        // Client connection should close itself
        try await clientConnectionChannel.closeFuture.get()

        try await serverChannel.close()
    }

    // This is an error because the client hasn't specified that it wants to receive push (by sending a MAX_PUSH_ID frame)
    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testIncomingPushStreamOnClient(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let firstServerConnectionChannelFuture = self.eventLoopGroup.any().makePromise(of: (any Channel).self)
        let serverErrorPromise = self.eventLoopGroup.any().makePromise(of: (any Error).self)

        /// Fulfills a promise with the channel that became active
        final class ChannelActiveWaiter: ChannelInboundHandler {
            typealias InboundIn = Never

            private let promise: EventLoopPromise<any Channel>

            init(promise: EventLoopPromise<any Channel>) {
                self.promise = promise
            }

            func channelActive(context: ChannelHandlerContext) {
                self.promise.succeed(context.channel)
                context.fireChannelActive()
            }
        }

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger,
            inboundConnectionInitializer: { connectionChannel in
                connectionChannel.eventLoop.makeCompletedFuture {
                    try connectionChannel.pipeline.syncOperations.addHandler(
                        ChannelActiveWaiter(promise: firstServerConnectionChannelFuture)
                    )
                    try connectionChannel.pipeline.syncOperations.addHandler(
                        ErrorCatchingHandler(errorPromise: serverErrorPromise)
                    )
                }
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger
        )

        // Wait for server to get an incoming connection
        let firstServerConnectionChannel = try await firstServerConnectionChannelFuture.futureResult.get()

        // Make a push stream from server to client
        let pushStreamChannel = try await firstServerConnectionChannel.makeHTTP3UnidirectionalStreamChannel(
            streamType: .push
        ).get()

        // Write the push id on the push stream
        _ = try await pushStreamChannel.eventLoop.submit {
            var buffer = ByteBuffer()
            buffer.writeEncodedInteger(10, strategy: .quic)
            pushStreamChannel.writeAndFlush(buffer, promise: nil)
        }.get()

        let serverConnectionError = try await serverErrorPromise.futureResult.get()
        let serverH3ConnectionError = serverConnectionError as? HTTP3Error
        #expect(serverH3ConnectionError?.code == .remoteConnectionError)
        #expect(serverH3ConnectionError?.h3ErrorCode == .idError)
        #expect(serverH3ConnectionError?.message == "Rejecting inbound push stream with invalid ID")

        // server and client connections should close themselves
        try await firstServerConnectionChannel.closeFuture.get()
        try await clientConnectionChannel.closeFuture.get()

        try await serverChannel.close()
    }

    @Test(
        .disabled("See DynamicTable document in NIOHTTP3 module"),
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testBadQPACKInstruction(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let settings = HTTP3Settings(
            qpackMaximumTableCapacity: 1024,
            qpackBlockedStreams: 10
        )

        // We do a write into the qpack stream on the server to make the server think the client sent a bad instruction.
        // The server should then send a connection error to the client.
        // We will look for that error.

        let clientErrorPromise = self.eventLoopGroup.any().makePromise(of: (any Error).self)

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: settings,
            logger: serverLogger,
            internalInboundStreamInitializer: { streamChannel, _, streamType in
                switch streamType {
                case .qpackEncoder:
                    // Write a bad instruction inbound, as if the peer has sent it
                    var buffer = ByteBuffer()
                    /// 0x20 followed by UInt.max means set the dynamic table size to UInt.max.
                    /// This is always an error on any platform, because UInt.max is always more than Int.max and therefore we don't allow it.
                    buffer.writeQPACKPrefixedInteger(UInt.max, prefix: 5, prefixBits: 0x20)
                    streamChannel.pipeline.fireChannelRead(buffer)
                case .qpackDecoder, .control:
                    break  // Not interested in these
                default: Issue.record("Not expecting any other streams")
                }
                return streamChannel.eventLoop.makeSucceededVoidFuture()
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: settings,
            logger: clientLogger,
            connectionInitializer: {
                $0.pipeline.addHandlers(ErrorCatchingHandler(errorPromise: clientErrorPromise))
            }
        )

        // Client will get a connection error
        let clientConnectionError = try await clientErrorPromise.futureResult.get()
        let clientH3ConnectionError = clientConnectionError as? HTTP3Error
        #expect(clientH3ConnectionError?.code == .remoteConnectionError)
        #expect(clientH3ConnectionError?.h3ErrorCode == .qpackEncoderStreamError)
        #expect(clientH3ConnectionError?.message == "Invalid QPACK instruction")

        // Client connection should close itself
        try await clientConnectionChannel.closeFuture.get()

        // Tear down
        try await serverChannel.close()
    }

    // If the connection handler gets a shouldquiesce event then the stream handlers should also
    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testForwardShouldQuiesce(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        /// Fulfills a promise when `ChannelShouldQuiesceEvent` is seen.
        final class ShouldQuiesceRecorder: ChannelInboundHandler, Sendable {
            typealias InboundIn = Never

            private let promise: EventLoopPromise<Void>

            init(promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                if event is ChannelShouldQuiesceEvent {
                    self.promise.succeed()
                }
            }
        }

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger
        )

        let gotQueisceOnStreamPromise = clientConnectionChannel.eventLoop.makePromise(of: Void.self)

        _ = try await clientConnectionChannel.makeHTTP3RequestChannel {
            try $0.channel.pipeline.syncOperations.addHandler(ShouldQuiesceRecorder(promise: gotQueisceOnStreamPromise))
        }.get()

        clientConnectionChannel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        try await gotQueisceOnStreamPromise.futureResult.get()

        try await clientConnectionChannel.close()
        try await serverChannel.close()
    }

    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testNoOutboundRequestsAfterGoawayReceived(
        authenticationConfiguration: AuthenticationConfiguration
    ) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        let inboundConnections = NIOLockedValueBox<[any Channel]>([])

        // Promises for controlling the 3rd, held-open request
        let requestReceivedPromise = self.eventLoopGroup.any().makePromise(of: Void.self)
        let responsePromise = self.eventLoopGroup.any().makePromise(of: Void.self)
        // Shared counter across all streams
        let sharedRequestCounter = NIOLockedValueBox<Int>(0)

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger,
            inboundConnectionInitializer: { conn in
                inboundConnections.withLockedValue { $0.append(conn) }
                return conn.eventLoop.makeSucceededVoidFuture()
            },
            inboundStreamInitializer: {
                let channel = $0.channel
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(HTTP3ToHTTPServerCodec())
                    // Handler uses shared counter to respond immediately for first 2, wait for 3rd
                    try channel.pipeline.syncOperations.addHandler(
                        ControllableEchoResponseHandler(
                            requestReceivedSignal: requestReceivedPromise,
                            responseSignal: responsePromise,
                            responseToSend: .init(status: .ok),
                            immediateResponseCount: 2,
                            requestCounter: sharedRequestCounter
                        )
                    )
                }
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger
        )

        func makeRequest() async throws {
            let inboundDataPromise = clientConnectionChannel.eventLoop.makePromise(of: [HTTPResponsePart].self)
            let requestStreamChannelFuture = clientConnectionChannel.makeHTTP3RequestChannel {
                try $0.channel.pipeline.syncOperations.addHandler(HTTP3ToHTTPClientCodec())
                try $0.channel.pipeline.syncOperations.addHandler(
                    InboundDataRecorder(promise: inboundDataPromise, targetCount: 3)
                )
            }

            let requestStreamChannel: any Channel
            do {
                requestStreamChannel = try await requestStreamChannelFuture.get()
            } catch {
                inboundDataPromise.fail(error)  // avoid leaking promise
                throw error
            }

            requestStreamChannel.write(
                HTTPRequestPart.head(
                    .init(method: .get, scheme: "http", authority: "test", path: "/", headerFields: [:])
                ),
                promise: nil
            )
            requestStreamChannel.write(HTTPRequestPart.body(buffer: .init(string: "hello world")), promise: nil)
            try await requestStreamChannel.writeAndFlush(HTTPRequestPart.end())

            let response = try await inboundDataPromise.futureResult.get()
            #expect(response[0] == .head(.init(status: .ok)))
        }

        // Make 2 requests that complete normally with echo response
        try await makeRequest()
        try await makeRequest()

        let inboundConnectionChannels = inboundConnections.withLockedValue { $0 }
        try #require(inboundConnectionChannels.count == 1)

        // Start a request in the background to keep the connection alive
        let activeRequestTask = Task {
            try await makeRequest()
        }

        // Wait for server to receive the request (stream 8 is now active)
        try await requestReceivedPromise.futureResult.get()

        // Server sends GOAWAY(12) - stream 8 < 12, so it's allowed to complete
        // Streams 0, 4 already completed. Stream 8 is active, so connection stays open.
        let serverH3HandlerFuture = inboundConnectionChannels[0].pipeline.handler(
            type: HTTP3ConnectionHandler<NIOQUIC.QUICStreamCreator>.self
        )
        try await serverH3HandlerFuture.flatMapThrowing {
            try $0.sendGoaway(id: 12)
        }.get()

        // Now client refuses new outbound requests because we received GOAWAY
        await #expect(throws: HTTP3Error.self) {
            try await makeRequest()
        }

        // Allow the active request (stream 8) to complete
        responsePromise.succeed()
        try await activeRequestTask.value
    }

    /// If the server closes the incoming control stream, the client should close the connection because that's a protocol violation.
    @Test(
        arguments: Self.standardAuthenticationConfigurations
    )
    @available(anyAppleOS 26, *)
    func testControlStreamClosed(authenticationConfiguration: AuthenticationConfiguration) async throws {
        let host = "127.0.0.1"

        let clientLogger = Logger(label: "Client")
        let serverLogger = Logger(label: "Server")

        // The server will send a `STOP_SENDING` on the control frame opened by the client.
        // What we want to test: The client will see that a critical stream has been closed by the remote peer, so it'll close the connection with an error as per RFC 9114 § 6.2.1.
        // However, the servers own connection state machine will also complain about the closed critical stream and try to close the connection.
        // To allow us to test what we actually want, we will intercept the event which server sends out to instruct the QUIC layer to close the stream.
        // Then, we will assert that the _client_ closes the stream by sending an error which is caught by the server.
        class QUICClosePreventer: ChannelOutboundHandler {
            typealias OutboundIn = Never

            func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?)
            {
                if event is QUICCloseConnectionEvent {
                    promise?.succeed()
                } else {
                    context.triggerUserOutboundEvent(event, promise: promise)
                }
            }
        }

        let serverConnectionErrorPromise = self.eventLoopGroup.next().makePromise(of: (any Error).self)

        let credentials = try TestCertificates.makeCredentials(for: authenticationConfiguration)

        let serverChannel = try await self.makeServer(
            credentials: credentials,
            host: host,
            settings: .init(),
            logger: serverLogger,
            inboundConnectionInitializer: { channel in
                channel.eventLoop.makeCompletedFuture {
                    let h3Handler = try channel.pipeline.syncOperations.handler(type: QUICHTTP3ConnectionHandler.self)
                    try channel.pipeline.syncOperations.addHandler(QUICClosePreventer(), position: .before(h3Handler))
                    try channel.pipeline.syncOperations.addHandler(
                        ErrorCatchingHandler(errorPromise: serverConnectionErrorPromise)
                    )
                }
            },
            inboundStreamInitializer: {
                // This is important. Although there is a control stream, that shouldn't be visible to us here
                Issue.record("Unexpected inbound stream with ID \($0.streamID)")
                return $0.channel.eventLoop.makeSucceededVoidFuture()
            },
            internalInboundStreamInitializer: { channel, _, streamType in
                switch streamType {
                case .control:
                    // Server will autoclose the inbound control stream
                    return channel.pipeline.addHandler(RequestStopSendingHandler())
                default:
                    // We don't care about this stream
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
            }
        )

        let serverPort = serverChannel.localAddress!.port!

        let clientConnectionChannel = try await self.makeClient(
            credentials: credentials,
            host: host,
            port: serverPort,
            settings: .init(),
            logger: clientLogger
        )

        try await clientConnectionChannel.closeFuture.get()

        let serverCaughtError = try await serverConnectionErrorPromise.futureResult.get()
        expectH3ErrorEqual(
            error: serverCaughtError,
            expectedCode: .remoteConnectionError,
            expectedH3ErrorCode: .closedCriticalStream
        )

        // Tear down
        try await serverChannel.close()
    }

    // MARK: - Helper Functions

    @available(anyAppleOS 26, *)
    private func makeServer(
        credentials: Credentials,
        host: String,
        port: Int = 0,
        settings: HTTP3Settings,
        logger: Logger,
        inboundConnectionInitializer: @Sendable @escaping (any Channel) -> EventLoopFuture<Void> = {
            $0.eventLoop.makeSucceededVoidFuture()
        },
        inboundStreamInitializer: @Sendable @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Void> = {
            $0.channel.eventLoop.makeSucceededVoidFuture()
        },
        internalInboundStreamInitializer:
            @escaping @Sendable (
                any Channel, QUICStreamID, HTTP3StreamType.Unidirectional
            ) -> EventLoopFuture<Void> = { c, _, _ in c.eventLoop.makeSucceededVoidFuture() }
    ) async throws -> any Channel {
        try await Self.createHTTP3ServerChannel(
            eventLoopGroup: self.eventLoopGroup,
            host: host,
            port: port,
            settings: settings,
            credentials: credentials,
            logger: logger,
            inboundConnectionInitializer: inboundConnectionInitializer,
            inboundStreamInitializer: inboundStreamInitializer,
            internalInboundStreamInitializer: internalInboundStreamInitializer
        )
    }

    @available(anyAppleOS 26, *)
    private func makeClient(
        credentials: Credentials,
        host: String,
        port: Int,
        settings: HTTP3Settings,
        logger: Logger,
        internalInboundStreamInitializer:
            @escaping @Sendable (
                any Channel, QUICStreamID, HTTP3StreamType.Unidirectional
            ) -> EventLoopFuture<Void> = { c, _, _ in c.eventLoop.makeSucceededVoidFuture() },
        connectionInitializer: (@Sendable (any Channel) -> EventLoopFuture<Void>)? = nil
    ) async throws -> any Channel {
        try await Self.createHTTP3ClientChannel(
            eventLoopGroup: self.eventLoopGroup,
            host: host,
            port: port,
            settings: settings,
            credentials: credentials,
            logger: logger,
            internalInboundStreamInitializer: internalInboundStreamInitializer,
            connectionInitializer: connectionInitializer
        )
    }

    @available(anyAppleOS 26, *)
    private static func createHTTP3ClientChannel(
        eventLoopGroup: any EventLoopGroup,
        host: String,
        port: Int,
        settings: HTTP3Settings,
        credentials: Credentials,
        logger: Logger,
        internalInboundStreamInitializer: (
            @Sendable (any Channel, QUICStreamID, HTTP3StreamType.Unidirectional) -> EventLoopFuture<Void>
        )? = nil,
        connectionInitializer: (@Sendable (any Channel) -> EventLoopFuture<Void>)? = nil
    ) async throws -> any Channel {
        let quicConfiguration: QUICConfiguration
        let serverName: String
        switch credentials {
        case .rawKeys(let name, let publicKeyPath, _, _):
            quicConfiguration = .makeH3ClientConfig(publicKeyPath: publicKeyPath)
            serverName = name
        case .certificates(let name, _, _, let trustRootsPath):
            quicConfiguration = .makeH3ClientConfig(trustedRootsPath: trustRootsPath)
            serverName = name
        }
        let h3ConnectionMultiplexer = try await DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    var config = HTTP3ClientConfiguration.defaults
                    config.emitFrames = true
                    return try channel.pipeline.syncOperations.configureHTTP3Client(
                        channel: channel,
                        configuration: config,
                        settings: settings,
                        quicConfiguration: quicConfiguration,
                        logger: logger,
                        internalInboundStreamInitializer: internalInboundStreamInitializer
                    )
                }
            }

        let httpChannelFuture = h3ConnectionMultiplexer.createConnectionChannel(
            serverName: serverName,
            remoteAddress: try! .init(ipAddress: host, port: port),
            connectionInitializer: connectionInitializer
        )

        return try await httpChannelFuture.get()
    }

    @available(anyAppleOS 26, *)
    private static func createHTTP3ServerChannel(
        eventLoopGroup: any EventLoopGroup,
        host: String,
        port: Int,
        settings: HTTP3Settings,
        credentials: Credentials,
        logger: Logger,
        inboundConnectionInitializer: @Sendable @escaping (any Channel) -> EventLoopFuture<Void> = {
            $0.eventLoop.makeSucceededVoidFuture()
        },
        inboundStreamInitializer: @Sendable @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Void> = {
            $0.channel.eventLoop.makeSucceededVoidFuture()
        },
        internalInboundStreamInitializer:
            @escaping @Sendable (
                any Channel, QUICStreamID, HTTP3StreamType.Unidirectional
            ) -> EventLoopFuture<Void> = { c, _, _ in c.eventLoop.makeSucceededVoidFuture() }
    ) async throws -> any Channel {
        let quicConfiguration: QUICConfiguration =
            switch credentials {
            case .rawKeys(let serverName, let publicKeyPath, let privateKeyPath, _):
                .makeH3ServerConfig(
                    serverName: serverName,
                    publicKeyPath: publicKeyPath,
                    privateKeyPath: privateKeyPath
                )
            case .certificates(_, let certPath, let keyPath, _):
                .makeH3ServerConfig(certPath: certPath, keyPath: keyPath)
            }
        let channel = try await DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    var config = HTTP3ServerConfiguration.defaults
                    config.emitFrames = true
                    try channel.pipeline.syncOperations.configureHTTP3Server(
                        channel: channel,
                        configuration: config,
                        settings: settings,
                        quicConfiguration: quicConfiguration,
                        logger: logger,
                        inboundConnectionInitializer: inboundConnectionInitializer,
                        inboundRequestStreamInitializer: inboundStreamInitializer,
                        internalInboundStreamInitializer: internalInboundStreamInitializer
                    )
                    return channel
                }
            }

        logger.info("Server started", metadata: ["port": "\(channel.localAddress!.port!)"])
        return channel
    }
}

extension Channel {
    /// Call this on a HTTP3 connection channel to make an outbound request stream.
    /// - Returns: The request stream channel.
    fileprivate func makeHTTP3RequestChannel(
        initializer: (@Sendable (HTTP3StreamInitializerParameters) throws -> Void)? = nil
    ) -> EventLoopFuture<any Channel> {
        self.pipeline.handler(
            type: QUICHTTP3ConnectionHandler.self
        )
        .flatMap {
            $0.createRequestStream { params in
                params.channel.eventLoop.makeCompletedFuture {
                    try initializer?(params)
                    return params.channel
                }
            }
        }
    }

    /// Call this on a HTTP3 connection channel to make an outbound unidirectional stream.
    /// - Returns: The stream channel.
    fileprivate func makeHTTP3UnidirectionalStreamChannel(
        streamType: HTTP3StreamType.Unidirectional,
        initializer: (@Sendable (HTTP3StreamInitializerParameters) throws -> Void)? = nil
    ) -> EventLoopFuture<any Channel> {
        self.pipeline.handler(
            type: QUICHTTP3ConnectionHandler.self
        )
        .flatMap {
            $0.createUnidirectionalStream(ofType: streamType) { params in
                params.channel.eventLoop.makeCompletedFuture {
                    try initializer?(params)
                    return params.channel
                }
            }
        }
    }
}
