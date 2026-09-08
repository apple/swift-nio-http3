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
@_spi(PackageInternal) import QPACK
@_spi(PackageInternal) import HTTP3

struct QPACKOutboundDecoderStream: ~Copyable, HTTP3.QPACKOutboundDecoderStream {
    private let channel: any Channel
    private let encoder: QPACKDecoderInstructionEncoder
    private var byteBuffer: ByteBuffer

    init(channel: any Channel) {
        self.channel = channel
        self.byteBuffer = channel.allocator.buffer(capacity: 1024)
        self.encoder = QPACKDecoderInstructionEncoder()
    }

    mutating func sendInstruction(_ instruction: QPACKDecoderInstruction) {
        self.byteBuffer.clear()
        self.encoder.encode(data: instruction, out: &self.byteBuffer)
        self.channel.writeAndFlush(self.byteBuffer, promise: nil)
    }

    mutating func sendInstructions(_ instructions: some Collection<QPACKDecoderInstruction>) {
        guard !instructions.isEmpty else { return }

        self.byteBuffer.clear()
        for instruction in instructions {
            self.encoder.encode(data: instruction, out: &self.byteBuffer)
        }
        self.channel.writeAndFlush(self.byteBuffer, promise: nil)
    }
}
