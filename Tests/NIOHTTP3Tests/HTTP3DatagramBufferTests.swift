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

import NIOCore
import NIOQUICHelpers
import Testing

@testable import NIOHTTP3

struct HTTP3DatagramBufferTests {
    @Test
    func emptyBuffer() {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 1024)
        #expect(buffer.totalSize == 0)
        #expect(buffer.unbufferDatagrams(forStream: 42) == nil)
    }

    @Test
    func appendWithSpace() {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 1024)
        buffer.append(.zeros(512, streamID: 1))
        #expect(buffer.totalSize == 512)

        buffer.append(.zeros(512, streamID: 1))
        #expect(buffer.totalSize == 1024)
    }

    @Test
    func appendDropsOversizedDatagram() {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 1024)
        buffer.append(.zeros(2048, streamID: 1))
        #expect(buffer.totalSize == 0)
        #expect(buffer.unbufferDatagrams(forStream: 1) == nil)
    }

    @Test
    func appendDropsOldDatagrams() {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 1024)
        buffer.append(.zeros(256, streamID: 1))
        #expect(buffer.totalSize == 256)

        buffer.append(.zeros(512, streamID: 1))
        #expect(buffer.totalSize == 768)

        // First datagram (256B) gets dropped
        buffer.append(.zeros(512, streamID: 1))
        #expect(buffer.totalSize == 1024)
    }

    @Test
    func discardDatagramsForStreamsAtOrAboveID() {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 1024)
        buffer.append(.zeros(10, streamID: 0))
        buffer.append(.zeros(20, streamID: 4))
        buffer.append(.zeros(30, streamID: 8))
        #expect(buffer.totalSize == 60)

        buffer.discardDatagrams(forStreamsAtOrAbove: 4)
        #expect(buffer.totalSize == 10)
        #expect(buffer.unbufferDatagrams(forStream: 4) == nil)
        #expect(buffer.unbufferDatagrams(forStream: 8) == nil)
        #expect(buffer.unbufferDatagrams(forStream: 0)?.count == 1)
    }

    @Test
    func discardAllDatagrams() {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 1024)
        buffer.append(.zeros(10, streamID: 1))
        buffer.append(.zeros(20, streamID: 2))
        #expect(buffer.totalSize == 30)

        buffer.discardAllDatagrams()
        #expect(buffer.totalSize == 0)
        #expect(buffer.unbufferDatagrams(forStream: 1) == nil)
        #expect(buffer.unbufferDatagrams(forStream: 2) == nil)
    }

    @Test
    func unbufferDatagrams() throws {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 1024)
        buffer.append(.zeros(10, streamID: 1))
        buffer.append(.zeros(20, streamID: 1))
        buffer.append(.zeros(30, streamID: 1))
        #expect(buffer.totalSize == 60)

        buffer.append(.zeros(10, streamID: 2))
        #expect(buffer.totalSize == 70)

        let maybeDatagrams = buffer.unbufferDatagrams(forStream: 1)
        #expect(buffer.totalSize == 10)

        let datagrams = try #require(maybeDatagrams)
        #expect(datagrams.count == 3)
        #expect(datagrams.map { $0.streamID } == [1, 1, 1])
        #expect(datagrams.map { $0.payload.readableBytes } == [10, 20, 30])
    }

    @Test
    func appendDropsInInsertionOrderAcrossStreams() throws {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 60)
        buffer.append(.zeros(10, streamID: 1))
        buffer.append(.zeros(20, streamID: 2))
        buffer.append(.zeros(30, streamID: 1))
        #expect(buffer.totalSize == 60)

        // Over limit by 5: the 10 byte datagram for stream 1 is the oldest, so it's dropped.
        buffer.append(.zeros(5, streamID: 2))
        #expect(buffer.totalSize == 55)

        let maybeStreamOne = buffer.unbufferDatagrams(forStream: 1)
        let streamOne = try #require(maybeStreamOne)
        #expect(streamOne.map { $0.payload.readableBytes } == [30])

        let maybeStreamTwo = buffer.unbufferDatagrams(forStream: 2)
        let streamTwo = try #require(maybeStreamTwo)
        #expect(streamTwo.map { $0.payload.readableBytes } == [20, 5])

        #expect(buffer.totalSize == 0)
    }

    @Test
    func appendDropsPartOfARun() throws {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 100)
        buffer.append(.zeros(10, streamID: 1))
        buffer.append(.zeros(10, streamID: 1))
        buffer.append(.zeros(10, streamID: 1))

        // Exceeds max size by 20: the first two datagrams from stream 1 should be dropped.
        buffer.append(.zeros(90, streamID: 2))
        #expect(buffer.totalSize == 100)

        let maybeStreamOne = buffer.unbufferDatagrams(forStream: 1)
        let streamOne = try #require(maybeStreamOne)
        #expect(streamOne.map { $0.payload.readableBytes } == [10])
        #expect(buffer.totalSize == 90)
    }

    @Test
    func appendSkipsAlreadyUnbufferedStreamsWhenDropping() throws {
        var buffer = HTTP3DatagramBuffer(maxAllowedSize: 1024)
        buffer.append(.zeros(10, streamID: 1))
        buffer.append(.zeros(10, streamID: 2))
        #expect(buffer.unbufferDatagrams(forStream: 1)?.count == 1)
        #expect(buffer.totalSize == 10)

        // There's still a run for stream 1 recorded: dropping datagrams must skip it and evict
        // stream 2's datagrams instead.
        buffer.append(.zeros(1020, streamID: 3))
        #expect(buffer.totalSize == 1020)
        #expect(buffer.unbufferDatagrams(forStream: 2) == nil)

        let maybeStreamThree = buffer.unbufferDatagrams(forStream: 3)
        let streamThree = try #require(maybeStreamThree)
        #expect(streamThree.map { $0.payload.readableBytes } == [1020])
    }
}

extension HTTP3Datagram {
    static func zeros(_ count: Int, streamID: QUICStreamID) -> HTTP3Datagram {
        HTTP3Datagram(streamID: streamID, payload: ByteBuffer(repeating: 0, count: count))
    }
}
