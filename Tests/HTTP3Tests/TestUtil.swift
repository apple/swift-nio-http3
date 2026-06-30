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

public import HTTP3
import NIOCore
import QPACK

extension String {
    var huffmanEncodedBytes: [UInt8] {
        var buffer = ByteBuffer()
        buffer.writeHuffmanEncoded(bytes: self.utf8)
        return .init(buffer: buffer)
    }
}

extension HTTP3PushID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}

extension HTTP3GoawayID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}
