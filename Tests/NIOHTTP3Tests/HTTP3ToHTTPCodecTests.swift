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
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOExtras
import NIOHTTP3
import NIOHTTPTypes
import NIOQUICHelpers
import Testing

struct HTTP3ToHTTPCodecTests {
    private let validRequestHead: HTTP3Frame = .headers([
        .init(name: .method, value: "GET"),
        .init(name: .scheme, value: "https"),
        .init(name: .authority, value: "test"),
        .init(name: .path, value: "/"),
    ])

    private let validResponseHead: HTTP3Frame = .headers([
        .init(name: .status, value: "200")
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
        try channel.writeOutbound(HTTPRequestPart.body(buffer: .init(bytes: [1, 2, 3])))
        try channel.writeOutbound(HTTPRequestPart.body(buffer: .init(bytes: [4, 5, 6])))
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

        try channel.writeInbound(self.validResponseHead)
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
        try channel.writeOutbound(HTTPResponsePart.body(buffer: .init(bytes: [1, 2, 3])))
        try channel.writeOutbound(HTTPResponsePart.body(buffer: .init(bytes: [4, 5, 6])))
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
    func serverCodecAbortsStreamWhenRequestIncompleteAndInputClosed() throws {
        let codec = HTTP3ToHTTPServerCodec()
        let outboundEvents = NIOLockedValueBox([])
        let outboundEventRecorder = DebugOutboundEventsHandler { event, _ in
            if case .triggerUserOutboundEvent(let outboundEvent) = event {
                outboundEvents.withLockedValue { $0.append(outboundEvent) }
            }
        }

        let eventLoop = EmbeddedEventLoop()
        let errorPromise = eventLoop.makePromise(of: (any Error).self)
        let errorRecorder = InboundErrorRecorder(errorPromise: errorPromise)

        let channel = EmbeddedChannel(handlers: [outboundEventRecorder, codec, errorRecorder], loop: eventLoop)

        // The client terminated the stream before even sending a request head.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // The server should abort its response stream with H3_REQUEST_INCOMPLETE.
        let events = outboundEvents.withLockedValue { $0 }
        try #require(events.count == 1)
        let resetStreamEvent = try #require(events.first as? QUICResetStreamEvent)
        #expect(resetStreamEvent.code == QUICApplicationErrorCode(.H3_REQUEST_INCOMPLETE))

        // The failure should also be surfaced to the application.
        let error = try errorPromise.futureResult.wait()
        let h3Error = try #require(error as? HTTP3Error)
        #expect(h3Error.code == .peerTerminatedStream)
        #expect(h3Error.h3ErrorCode == .H3_REQUEST_INCOMPLETE)
    }

    @Test
    func clientCodecFiresErrorWhenResponseIncompleteAndInputClosed() throws {
        let codec = HTTP3ToHTTPClientCodec()

        let eventLoop = EmbeddedEventLoop()
        let errorPromise = eventLoop.makePromise(of: (any Error).self)
        let errorRecorder = InboundErrorRecorder(errorPromise: errorPromise)

        let responsePartsPromise = eventLoop.makePromise(of: [HTTPResponsePart].self)
        let responsePartsRecorder = InboundDataRecorder(promise: responsePartsPromise, targetCount: 2)

        let channel = EmbeddedChannel(handlers: [codec, errorRecorder, responsePartsRecorder], loop: eventLoop)

        // The client receives two interim responses, after which the server cleanly closes its send side.
        try channel.writeInbound(HTTP3Frame.headers([.init(name: .status, value: "100")]))
        try channel.writeInbound(HTTP3Frame.headers([.init(name: .status, value: "103")]))
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // But the response is incomplete since the server didn't send a final response...
        let parts = try responsePartsPromise.futureResult.wait()
        try #require(parts.count == 2)
        #expect(parts[0] == .head(.init(status: .continue)))
        #expect(parts[1] == .head(.init(status: .earlyHints)))

        // so the client should surface an error to the application.
        let error = try errorPromise.futureResult.wait()
        let h3Error = try #require(error as? HTTP3Error)
        #expect(h3Error.code == .peerTerminatedStream)
        #expect(h3Error.h3ErrorCode == .H3_NO_ERROR)
    }

    @Test
    func serverCodecDoesNotAbortStreamWhenRequestCompleted() throws {
        let codec = HTTP3ToHTTPServerCodec()

        let outboundEvents = NIOLockedValueBox([])
        let outboundEventRecorder = DebugOutboundEventsHandler { event, _ in
            if case .triggerUserOutboundEvent(let outboundEvent) = event {
                outboundEvents.withLockedValue { $0.append(outboundEvent) }
            }
        }

        let eventLoop = EmbeddedEventLoop()
        let requestPartsPromise = eventLoop.makePromise(of: [HTTPRequestPart].self)
        let requestPartsRecorder = InboundDataRecorder(promise: requestPartsPromise, targetCount: 2)

        let channel = EmbeddedChannel(handlers: [outboundEventRecorder, codec, requestPartsRecorder], loop: eventLoop)
        print(channel.pipeline)

        // The server receives a complete request, after which the client cleanly closes its send side.
        try channel.writeInbound(self.validRequestHead)
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Since the request was complete...
        let parts = try requestPartsPromise.futureResult.wait()
        try #require(parts.count == 2)
        #expect(parts[0] == .head(.init(method: .get, scheme: "https", authority: "test", path: "/")))
        #expect(parts[1] == .end(nil))

        // the stream must not be aborted.
        #expect(outboundEvents.withLockedValue { $0 }.isEmpty)
    }
}
