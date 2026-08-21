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

import NIOEmbedded
@testable import NIOHTTP3
@_spi(PackageInternal) import QPACK
import Testing

struct QPACKOutboundDecoderStreamHandlerTests {
    @Test
    func testWriteInstructions() throws {
        let loop = EmbeddedEventLoop()
        let handler = QPACKOutboundDecoderStreamHandler()
        let dataPromise = loop.makePromise(of: [QPACKDecoderInstruction].self)
        let recorder = OutboundDataRecorder(promise: dataPromise, targetCount: 1)
        let channel = EmbeddedChannel(handlers: [recorder, handler])
        // Connect to make channel become active
        _ = try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 12345))

        handler.sendInstructions([.sectionAcknowledgement(streamID: 100)])

        let writtenFrames = try dataPromise.futureResult.wait()
        #expect(writtenFrames == [.sectionAcknowledgement(streamID: 100)])
    }

    @Test
    func testWriteBlankInstructionsBeforeReady() {
        let handler = QPACKOutboundDecoderStreamHandler()
        // Assertion here is that it doesn't crash, it early returns because the context isn't set
        handler.sendInstructions([])
    }
}
