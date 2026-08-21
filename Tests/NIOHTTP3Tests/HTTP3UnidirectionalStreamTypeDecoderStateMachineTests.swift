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
@testable import NIOHTTP3
import Testing

import struct NIOCore.ByteBuffer

struct HTTP3UnidirectionalStreamTypeDecoderStateMachineTests {
    @Test
    func getsStreamType() {
        var stateMachine = HTTP3UnidirectionalStreamTypeDecoderStateMachine()

        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(0, strategy: .quic)  // Control streams are type 0
        #expect(buffer.readableBytes == 1)

        let action = stateMachine.buffer(data: buffer)
        #expect(action == .gotStreamType(.control))

        // We didn't buffer anything more than the stream type, so nothing to unbuffer
        #expect(stateMachine.unbufferElement() == .done)
    }

    @Test
    func getsMultiByteStreamType() {
        var stateMachine = HTTP3UnidirectionalStreamTypeDecoderStateMachine()

        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(100_000, strategy: .quic)
        #expect(buffer.readableBytes == 4)

        // We'll drip in the data byte by byte, except the last byte. This will return no action
        let bytes = buffer.readableBytesView.map { $0 }
        for byte in bytes.dropLast() {
            let partBuffer = ByteBuffer(bytes: [byte])
            let action = stateMachine.buffer(data: partBuffer)
            #expect(action == nil)
        }

        // Then we put in the final byte, which will tell us the stream type
        let action1 = stateMachine.buffer(data: .init(bytes: [bytes.last!]))
        #expect(action1 == .gotStreamType(.unknown(raw: 100_000)))

        // We didn't buffer anything more than the stream type, so nothing to unbuffer
        #expect(stateMachine.unbufferElement() == .done)
    }

    @Test
    func queuesBytesAfterStreamType() {
        var stateMachine = HTTP3UnidirectionalStreamTypeDecoderStateMachine()

        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(2, strategy: .quic)
        #expect(buffer.readableBytes == 1)

        // Send extra data after the stream type
        buffer.writeString("hello")

        let action1 = stateMachine.buffer(data: buffer)
        // We should get back the type, and rest gets queued
        #expect(action1 == .gotStreamType(.qpackEncoder))

        // The buffered bytes, hello, should be released
        #expect(stateMachine.unbufferElement() == .release(ByteBuffer(string: "hello")))
        #expect(stateMachine.unbufferElement() == .done)
    }

    @Test
    func queuesBytesAfterStreamTypeMultiByte() {
        // This test specifically is for the scenario where it takes multiple bytes to get the stream type, and each of those bytes comes
        // separately and thus needs to be buffered, but the final incoming bytebuffer, the one which contains the last byte needed for the
        // stream type, also contains extra bytes. We need to make sure those extra bytes make it to the next handler
        var stateMachine = HTTP3UnidirectionalStreamTypeDecoderStateMachine()

        // The 4b and b8 together make the quic integer 3000. The 01 and 02 are the extra bytes which should make it into the next handler
        let firstBuffer = ByteBuffer(bytes: [0x4b])
        let secondBuffer = ByteBuffer(bytes: [0xb8, 0x01])
        let thirdBuffer = ByteBuffer(bytes: [0x02])

        let action1 = stateMachine.buffer(data: firstBuffer)
        let action2 = stateMachine.buffer(data: secondBuffer)
        let action3 = stateMachine.buffer(data: thirdBuffer)

        #expect(action1 == nil)
        #expect(action2 == .gotStreamType(.unknown(raw: 3000)))
        #expect(action3 == nil)

        #expect(stateMachine.unbufferElement() == .release(ByteBuffer(bytes: [0x01])))
        #expect(stateMachine.unbufferElement() == .release(ByteBuffer(bytes: [0x02])))
        #expect(stateMachine.unbufferElement() == .done)
    }

    @Test
    func bufferNewBytesWhilstUnbuffering() {
        var stateMachine = HTTP3UnidirectionalStreamTypeDecoderStateMachine()

        var firstBuffer = ByteBuffer()
        firstBuffer.writeEncodedInteger(HTTP3StreamType.Unidirectional.push.rawValue, strategy: .quic)
        firstBuffer.writeString("hello")

        // Buffer the type + 'hello'
        #expect(stateMachine.buffer(data: firstBuffer) == .gotStreamType(.push))

        // Buffer some test data
        #expect(stateMachine.buffer(data: .init(string: "test1")) == nil)
        #expect(stateMachine.buffer(data: .init(string: "test2")) == nil)

        // Release one data
        #expect(stateMachine.unbufferElement() == .release(.init(string: "hello")))

        // Enqueue more test data. This is the real test: we can enqueue data after we started releasing
        #expect(stateMachine.buffer(data: .init(string: "test3")) == nil)

        // Release one more data
        #expect(stateMachine.unbufferElement() == .release(.init(string: "test1")))

        // Enqueue more test data again
        #expect(stateMachine.buffer(data: .init(string: "test4")) == nil)

        // Release all data
        #expect(stateMachine.unbufferElement() == .release(.init(string: "test2")))
        #expect(stateMachine.unbufferElement() == .release(.init(string: "test3")))
        #expect(stateMachine.unbufferElement() == .release(.init(string: "test4")))
        #expect(stateMachine.unbufferElement() == .done)
    }

    @Test
    func dropsBytesAfterAbort() {
        var stateMachine = HTTP3UnidirectionalStreamTypeDecoderStateMachine()

        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(HTTP3StreamType.Unidirectional.qpackEncoder.rawValue, strategy: .quic)
        #expect(buffer.readableBytes == 1)

        // Send extra data after the stream type
        buffer.writeString("hello")

        let action1 = stateMachine.buffer(data: buffer)
        // We should get back the type, and rest gets queued
        #expect(action1 == .gotStreamType(.qpackEncoder))

        stateMachine.abortReading()
        // There is nothing we can assert here, but the test is still useful because it ensures we don't hit a fatalError etc
    }
}
