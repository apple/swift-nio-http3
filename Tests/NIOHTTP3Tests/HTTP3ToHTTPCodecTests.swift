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

import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOExtras
import NIOHTTP3
import NIOHTTPTypes
import Testing

@_spi(PackageInternal) @testable import HTTP3

struct HTTP3ToHTTPCodecTests {
    private let validRequestHead: HTTP3Frame = .headers([
        .init(name: .method, value: "GET"),
        .init(name: .scheme, value: "https"),
        .init(name: .authority, value: "test"),
        .init(name: .path, value: "/"),
    ])

    private let validFinalResponseHead: HTTP3Frame = .headers([
        .init(name: .status, value: "200")
    ])

    private let validInterimResponseHead: HTTP3Frame = .headers([
        .init(name: .status, value: "103")
    ])

    @Test
    func testClientCodecWrite() throws {
        let handler = HTTP3ToHTTPClientCodec()
        let eventLoop = EmbeddedEventLoop()
        let framesPromise = eventLoop.makePromise(of: [WriteOrClose<HTTP3Frame>].self)
        let recorder = OutboundDataRecorderWithClose(promise: framesPromise, targetCount: 5)
        let channel = EmbeddedChannel(handlers: [recorder, handler], loop: eventLoop)

        try channel.writeOutbound(
            HTTPRequestPart.head(.init(method: .get, scheme: "https", authority: "test", path: "/"))
        )
        try channel.writeOutbound(HTTPRequestPart.body(.init(bytes: [1, 2, 3])))
        try channel.writeOutbound(HTTPRequestPart.body(.init(bytes: [4, 5, 6])))
        try channel.writeOutbound(HTTPRequestPart.end([.cookie: "test"]))

        let events = try framesPromise.futureResult.wait()
        try #require(events.count == 5)
        // frame 0 should contain the headers, in any order
        guard case .write(.headers(let headerPayload)) = events[0] else {
            Issue.record("Expected headers, got \(events[0])")
            return
        }
        let headers = headerPayload.fields
        try #require(headers.count == 4)
        #expect(headers.contains(where: { $0.name == .method && $0.value == "GET" }))
        #expect(headers.contains(where: { $0.name == .scheme && $0.value == "https" }))
        #expect(headers.contains(where: { $0.name == .path && $0.value == "/" }))
        #expect(headers.contains(where: { $0.name == .authority && $0.value == "test" }))

        // Next 2 frames should be data
        #expect(events[1] == .write(.data(.init(bytes: [1, 2, 3]))))
        #expect(events[2] == .write(.data(.init(bytes: [4, 5, 6]))))

        // last frame should be trailers, in any order
        guard case .write(.headers(let trailerPayload)) = events[3] else {
            Issue.record("Expected headers, got \(events[3])")
            return
        }
        let trailers = trailerPayload.fields
        #expect(trailers.count == 1)
        #expect(trailers.contains(where: { $0.name == .cookie && $0.value == "test" }))

        // Finally, a close
        #expect(events[4] == .close)
    }

    @Test
    func testClientCodecRead() throws {
        let handler = HTTP3ToHTTPClientCodec()
        let eventLoop = EmbeddedEventLoop()
        let partsPromise = eventLoop.makePromise(of: [HTTPResponsePart].self)
        let recorder = InboundDataRecorder(promise: partsPromise, targetCount: 3)
        let channel = EmbeddedChannel(handlers: [handler, recorder], loop: eventLoop)

        try channel.writeInbound(self.validFinalResponseHead)
        try channel.writeInbound(HTTP3Frame.data(.init(bytes: [1, 2, 3])))
        try channel.writeInbound(HTTP3Frame.data(.init(bytes: [1, 2, 3])))

        let parts = try partsPromise.futureResult.wait()
        try #require(parts.count == 3)
        // first part should be the head
        #expect(parts[0] == .head(HTTPResponse(status: .ok)))
        // Next 2 frames should be data
        #expect(parts[1] == .body(.init(bytes: [1, 2, 3])))
        #expect(parts[2] == .body(.init(bytes: [1, 2, 3])))
    }

    @Test
    func testServerCodecWrite() throws {
        let handler = HTTP3ToHTTPServerCodec()
        let eventLoop = EmbeddedEventLoop()
        let framesPromise = eventLoop.makePromise(of: [WriteOrClose<HTTP3Frame>].self)
        let recorder = OutboundDataRecorderWithClose(promise: framesPromise, targetCount: 5)
        let channel = EmbeddedChannel(handlers: [recorder, handler], loop: eventLoop)

        try channel.writeOutbound(HTTPResponsePart.head(.init(status: .ok)))
        try channel.writeOutbound(HTTPResponsePart.body(.init(bytes: [1, 2, 3])))
        try channel.writeOutbound(HTTPResponsePart.body(.init(bytes: [4, 5, 6])))
        try channel.writeOutbound(HTTPResponsePart.end([.cookie: "test"]))

        var events = [WriteOrClose<HTTP3Frame>]()
        events = try framesPromise.futureResult.wait()
        try #require(events.count == 5)
        // frame 0 should contain the headers, in any order
        guard case .write(.headers(let headers)) = events[0] else {
            Issue.record("Expected headers, got \(events[0])")
            return
        }
        try #require(headers.fields.count == 1)
        #expect(headers.fields.contains(where: { $0.name == .status && $0.value == "200" }))

        // Next 2 frames should be data
        #expect(events[1] == .write(.data(.init(bytes: [1, 2, 3]))))
        #expect(events[2] == .write(.data(.init(bytes: [4, 5, 6]))))

        // last frame should be trailers, in any order
        guard case .write(.headers(let trailers)) = events[3] else {
            Issue.record("Expected headers, got \(events[3])")
            return
        }
        try #require(trailers.fields.count == 1)
        #expect(trailers.fields.contains(where: { $0.name == .cookie && $0.value == "test" }))

        // Finally, a close
        #expect(events[4] == .close)
    }

    @Test
    func testServerCodecRead() throws {
        let handler = HTTP3ToHTTPServerCodec()
        let eventLoop = EmbeddedEventLoop()
        let partsPromise = eventLoop.makePromise(of: [HTTPRequestPart].self)
        let recorder = InboundDataRecorder(promise: partsPromise, targetCount: 3)
        let channel = EmbeddedChannel(handlers: [handler, recorder], loop: eventLoop)

        try channel.writeInbound(self.validRequestHead)
        try channel.writeInbound(HTTP3Frame.data(.init(bytes: [1, 2, 3])))
        try channel.writeInbound(HTTP3Frame.data(.init(bytes: [1, 2, 3])))

        let parts = try partsPromise.futureResult.wait()
        try #require(parts.count == 3)
        // first part should be the head
        #expect(parts[0] == .head(.init(method: .get, scheme: "https", authority: "test", path: "/")))
        // Next 2 frames should be data
        #expect(parts[1] == .body(.init(bytes: [1, 2, 3])))
        #expect(parts[2] == .body(.init(bytes: [1, 2, 3])))
    }

    @Test
    func serverCodecGeneratesEndPartForCompleteRequestUponInputClosed() throws {
        let eventLoop = EmbeddedEventLoop()
        let partsPromise = eventLoop.makePromise(of: [HTTPRequestPart].self)
        let dataRecorder = InboundDataRecorder(promise: partsPromise, targetCount: 2)

        let codec = HTTP3ToHTTPServerCodec()

        let channel = EmbeddedChannel(handlers: [codec, dataRecorder], loop: eventLoop)

        // Write a request head and then close the input side.
        try channel.writeInbound(self.validRequestHead)
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        let parts = try partsPromise.futureResult.wait()
        try #require(parts.count == 2)
        #expect(parts[0] == .head(.init(method: .get, scheme: "https", authority: "test", path: "/")))
        #expect(parts[1] == .end(nil))
    }

    @Test
    func clientCodecGeneratesEndPartForCompleteResponseUponInputClosed() throws {
        let eventLoop = EmbeddedEventLoop()
        let partsPromise = eventLoop.makePromise(of: [HTTPResponsePart].self)
        let dataRecorder = InboundDataRecorder(promise: partsPromise, targetCount: 2)

        let codec = HTTP3ToHTTPClientCodec()

        let channel = EmbeddedChannel(handlers: [codec, dataRecorder], loop: eventLoop)

        // Write a response head and then close the input side.
        try channel.writeInbound(self.validFinalResponseHead)
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        let parts = try partsPromise.futureResult.wait()
        try #require(parts.count == 2)
        #expect(parts[0] == .head(.init(status: .ok)))
        #expect(parts[1] == .end(nil))
    }

    @Test
    func serverCodecDoesNotFireChannelReadWhenNoRequest() throws {
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: [Void].self)
        let inboundEvents = NIOLockedValueBox<[DebugInboundEventsHandler.Event]>([])
        let eventRecorder = DebugInboundEventsHandler { event, context in
            inboundEvents.withLockedValue { $0.append(event) }
        }

        let codec = HTTP3ToHTTPServerCodec()

        let channel = EmbeddedChannel(handlers: [codec, eventRecorder], loop: eventLoop)

        // The client terminated the stream before even sending a request head.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // We expect the server codec to not fire any channelReads if no request parts were sent before the input closed;
        // `HTTP3StreamHandler` handles this case by resetting the stream and firing an error down the pipeline.
        let events = inboundEvents.withLockedValue { $0 }
        #expect(events.count == 2)
        #expect(events[0].isChannelRegistered)
        #expect(events[1].isInputClosedEvent)

        // Clean up the promise as it never gets fulfilled.
        promise.succeed([Void]())
    }

    @Test(arguments: [true, false])
    func clientCodecDoesNotEmitEndWhenResponseIncomplete(includeInterimResponses: Bool) throws {
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: [HTTPResponsePart].self)
        let dataRecorder = InboundDataRecorder(promise: promise, targetCount: includeInterimResponses ? 2 : 0)

        let codec = HTTP3ToHTTPClientCodec()

        let channel = EmbeddedChannel(handlers: [codec, dataRecorder], loop: eventLoop)

        if includeInterimResponses {
            // Receiving interim response head(s) does not mean the response is complete; the response is only
            // considered complete once a *final* response head is received.
            try channel.writeInbound(self.validInterimResponseHead)
            try channel.writeInbound(self.validInterimResponseHead)
        }

        // The server terminated the stream before sending a final response head.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // We expect the client codec to not generate an end part if the response is incomplete when the input closed;
        // `HTTP3StreamHandler` handles this case by firing an error down the pipeline.
        if includeInterimResponses {
            let parts = try promise.futureResult.wait()
            try #require(parts.count == 2)
            #expect(parts[0] == .head(.init(status: .earlyHints)))
            #expect(parts[1] == .head(.init(status: .earlyHints)))
        } else {
            // We expect the client codec to not deliver anything when nothing was sent before the input closed.
            #expect(dataRecorder.getDataOnEventloop().count == 0)

            // Clean up the promise as it never gets fulfilled when `includeInterimResponse` == `false`.
            promise.succeed([HTTPResponsePart]())
        }
    }
}
