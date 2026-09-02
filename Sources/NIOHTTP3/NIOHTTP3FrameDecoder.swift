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
import NIOCore

struct NIOHTTP3FrameDecoder: NIOSingleStepByteToMessageDecoder {
    typealias InboundOut = HTTP3PartialFrameOrUnknown

    var underlying: HTTP3FrameDecoder

    init() {
        self.underlying = .init()
    }

    mutating func decode(buffer: inout ByteBuffer) throws -> HTTP3PartialFrameOrUnknown? {
        try self.underlying.decode(buffer: &buffer)
    }

    mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> HTTP3PartialFrameOrUnknown? {
        try self.underlying.decodeLast(buffer: &buffer, seenEOF: seenEOF)
    }
}
