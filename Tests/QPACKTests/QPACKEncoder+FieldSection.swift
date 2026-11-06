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
import NIOCore
import NIOQUICHelpers
import Testing

@_spi(PackageInternal) @testable import QPACK

// The encoders write their field sections straight into an `OutputRawSpan`. These read them back as a `FieldSection`,
// which the tests can compare line by line. They give the encoders exactly the room they ask for.

/// Runs `encode` on a span of exactly `maxLength` bytes, and returns the bytes it wrote alongside its result.
///
/// Writing more than `maxLength` bytes traps. A `ByteBuffer` rounds its capacity up, which would hide that.
@available(anyAppleOS 27, *)
func encodeWithExactRoom<Result>(
    _ maxLength: Int,
    _ encode: (inout OutputRawSpan) -> Result
) -> (ByteBuffer, Result) {
    var bytes = [UInt8](repeating: 0, count: maxLength)
    let (length, result) = bytes.withUnsafeMutableBytes { buffer in
        var output = OutputRawSpan(buffer: buffer, initializedCount: 0)
        let result = encode(&output)
        return (output.finalize(for: buffer), result)
    }
    return (ByteBuffer(bytes: bytes.prefix(length)), result)
}

/// The result of encoding a field section.
@available(anyAppleOS 27, *)
struct QPACKEncodeResult {
    var fieldSection: FieldSection
    var instructions: [QPACKEncoderInstruction]
}

@available(anyAppleOS 27, *)
extension FieldSection {
    /// Reads the field section which takes up the whole of `buffer`.
    init(readingAll buffer: ByteBuffer, sourceLocation: SourceLocation = #_sourceLocation) {
        var buffer = buffer
        self = try! buffer.readFieldSection()!
        #expect(buffer.readableBytes == 0, sourceLocation: sourceLocation)
    }
}

@available(anyAppleOS 27, *)
extension StaticQPACKEncoder {
    /// The field section the encoder writes for `headers`, read back from its bytes.
    func encode(headers: [HTTPField], sourceLocation: SourceLocation = #_sourceLocation) -> FieldSection {
        let (buffer, _) = encodeWithExactRoom(self.maxEncodedLength(of: headers)) { output in
            self.encode(headers: headers, into: &output, preferHuffmanEncoding: false)
        }
        return FieldSection(readingAll: buffer, sourceLocation: sourceLocation)
    }
}

@available(anyAppleOS 27, *)
extension DynamicQPACKEncoder {
    /// The field section the encoder writes for `headers`, read back from its bytes, and the instructions it returns.
    mutating func encode(
        headers: [HTTPField],
        forStream streamID: QUICStreamID,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> QPACKEncodeResult {
        let (buffer, instructions) = encodeWithExactRoom(self.maxEncodedLength(of: headers)) { output in
            self.encode(headers: headers, forStream: streamID, into: &output, preferHuffmanEncoding: false)
        }
        return QPACKEncodeResult(
            fieldSection: FieldSection(readingAll: buffer, sourceLocation: sourceLocation),
            instructions: instructions
        )
    }
}

@available(anyAppleOS 27, *)
extension QPACKStateMachine {
    /// The field section the state machine's encoder writes for `headers`, read back from its bytes, and the
    /// instructions it returns.
    mutating func encodeHeaders(
        _ headers: [HTTPField],
        forStream streamID: QUICStreamID,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> QPACKEncodeResult {
        let (buffer, instructions) = encodeWithExactRoom(self.maxEncodedLength(of: headers)) { output in
            self.encodeHeaders(headers, forStream: streamID, into: &output, preferHuffmanEncoding: false)
        }
        return QPACKEncodeResult(
            fieldSection: FieldSection(readingAll: buffer, sourceLocation: sourceLocation),
            instructions: instructions
        )
    }
}
