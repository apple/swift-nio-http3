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

public import HTTPTypes
public import NIOQUICHelpers
@_spi(PackageInternal) @_spi(Benchmarks) private import QPACK

// QPACK isn't a library product, so add entry points for benchmarks here under SPI.
@available(anyAppleOS 27, *)
@_spi(Benchmarks)
public enum QPACKBenchmarks {
    /// Encode `headers` with the static-only encoder. Returns the number of bytes the field
    /// section takes.
    ///
    /// The return value doesn't matter, but needs to be there so the calling benchmark
    /// can stop the function call from being optimised away.
    @_spi(Benchmarks)
    public static func staticEncode(headers: [HTTPField]) -> Int {
        let encoder = StaticQPACKEncoder()
        return Self.withOutputRawSpan(capacity: encoder.maxEncodedLength(of: headers)) { output in
            encoder.encode(fields: headers, into: &output, preferHuffmanEncoding: true)
        }
    }

    /// Create a dynamic encoder and encode `headers` on `streamID`. Returns the number
    /// of bytes the field section takes.
    ///
    /// The return value doesn't matter, but needs to be there so the calling benchmark
    /// can stop the function call from being optimised away.
    @_spi(Benchmarks)
    public static func dynamicEncode(
        headers: [HTTPField],
        streamID: QUICStreamID,
        dynamicTableMaxCapacity: Int,
        dynamicTableInitialCapacity: Int,
        maxBlockedStreams: Int,
        targetEvictableFraction: Double
    ) -> Int {
        var (encoder, _) = DynamicQPACKEncoder.create(
            peersDecoderTableMaxCapacity: dynamicTableMaxCapacity,
            dynamicTableMaxCapacity: dynamicTableMaxCapacity,
            dynamicTableInitialCapacity: dynamicTableInitialCapacity,
            maxBlockedStreams: maxBlockedStreams,
            targetEvictableFraction: targetEvictableFraction
        )
        return Self.withOutputRawSpan(capacity: encoder.maxEncodedLength(of: headers)) { output in
            _ = encoder.encode(headers: headers, forStream: streamID, into: &output, preferHuffmanEncoding: true)
        }
    }

    /// Calls `body` with an `OutputRawSpan` over stack memory, and returns the number of bytes it appended.
    private static func withOutputRawSpan(capacity: Int, _ body: (inout OutputRawSpan) -> Void) -> Int {
        withUnsafeTemporaryAllocation(byteCount: capacity, alignment: 1) { buffer in
            var output = OutputRawSpan(buffer: buffer, initializedCount: 0)
            body(&output)
            return output.finalize(for: buffer)
        }
    }
}
