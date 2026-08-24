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
import NIOEmbedded
import Testing

@testable import NIOHTTP3

struct HTTP3OutboundControlStreamHandlerTests {
    let testSettings = HTTP3Settings(qpackMaximumTableCapacity: 100)

    @Test
    func writesSettings_handlerAddedThenActive() throws {
        let loop = EmbeddedEventLoop()
        let handler = HTTP3OutboundControlStreamHandler(settings: self.testSettings)
        let dataPromise = loop.makePromise(of: [HTTP3Frame].self)
        let recorder = OutboundDataRecorder(promise: dataPromise, targetCount: 1)
        let channel = EmbeddedChannel(handlers: [recorder, handler])
        // Connect to make channel become active
        _ = try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 12345))
        let writtenFrames = try dataPromise.futureResult.wait()
        #expect(writtenFrames == [.settings(self.testSettings)])
    }

    @Test
    func writesSettings_activeThenHandlerAdded() throws {
        let loop = EmbeddedEventLoop()
        let handler = HTTP3OutboundControlStreamHandler(settings: self.testSettings)
        let dataPromise = loop.makePromise(of: [HTTP3Frame].self)
        let recorder = OutboundDataRecorder(promise: dataPromise, targetCount: 1)
        let channel = EmbeddedChannel(handler: recorder)
        // Connect to make channel become active
        _ = try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 12345))
        // Then add the handler
        try channel.pipeline.syncOperations.addHandler(handler)
        let writtenFrames = try dataPromise.futureResult.wait()
        #expect(writtenFrames == [.settings(self.testSettings)])
    }

    @Test
    func writeGoawayBeforeActiveOrAdded() throws {
        let loop = EmbeddedEventLoop()
        let handler = HTTP3OutboundControlStreamHandler(settings: self.testSettings)

        handler.sendGoaway(id: 10)

        let dataPromise = loop.makePromise(of: [HTTP3Frame].self)
        let recorder = OutboundDataRecorder(promise: dataPromise, targetCount: 2)
        let channel = EmbeddedChannel(handlers: [recorder, handler])
        // Connect to make channel become active
        _ = try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 12345))
        let writtenFrames = try dataPromise.futureResult.wait()
        #expect(writtenFrames == [.settings(self.testSettings), .goaway(10)])
    }

    @Test
    func writeGoawayAfterActiveAndAdded() throws {
        let loop = EmbeddedEventLoop()
        let handler = HTTP3OutboundControlStreamHandler(settings: self.testSettings)

        let dataPromise = loop.makePromise(of: [HTTP3Frame].self)
        let recorder = OutboundDataRecorder(promise: dataPromise, targetCount: 2)
        let channel = EmbeddedChannel(handlers: [recorder, handler])
        // Connect to make channel become active
        _ = try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 12345))

        handler.sendGoaway(id: 10)

        let writtenFrames = try dataPromise.futureResult.wait()
        #expect(writtenFrames == [.settings(self.testSettings), .goaway(10)])
    }
}
