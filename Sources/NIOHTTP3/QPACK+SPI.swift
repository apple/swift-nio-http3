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
private import QPACK

// QPACK isn't a library product, so add entry points for benchmarks here under SPI.
@_spi(Benchmarks)
public enum QPACKBenchmarks {
    /// Encode `headers` with the static-only encoder. Returns the number of field lines
    /// produced.
    ///
    /// The return value doesn't matter, but needs to be there so the calling benchmark
    /// can stop the function call from being optimised away.
    @_spi(Benchmarks)
    public static func staticEncode(headers: [HTTPField]) -> Int {
        let encoder = StaticQPACKEncoder()
        return encoder.encode(headers: headers).lines.count
    }

    /// Create a dynamic encoder and encode `headers` on `streamID`. Returns the number
    /// of field lines produced.
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
            dynamicTableMaxCapacity: dynamicTableMaxCapacity,
            dynamicTableInitialCapacity: dynamicTableInitialCapacity,
            maxBlockedStreams: maxBlockedStreams,
            targetEvictableFraction: targetEvictableFraction
        )
        return encoder.encode(headers: headers, forStream: streamID).fieldSection.lines.count
    }
}
