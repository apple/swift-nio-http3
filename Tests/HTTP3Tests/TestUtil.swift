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

@testable import QPACK

extension String {
    @available(anyAppleOS 27, *)
    var huffmanEncodedBytes: [UInt8] {
        let length = self.withContiguousUTF8 { QPACKEncodedLength.huffman(of: $0) }
        let buffer = ByteBuffer(initialCapacity: length) { output in
            self.withContiguousUTF8 { output.appendHuffmanEncoded($0, encodedByteLength: length) }
        }
        return Array(buffer.readableBytesView)
    }
}

@available(anyAppleOS 27, *)
extension HTTP3PushID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}

@available(anyAppleOS 27, *)
extension HTTP3GoawayID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}
