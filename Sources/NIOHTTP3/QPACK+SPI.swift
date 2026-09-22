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
@_spi(PackageInternal) @_spi(Benchmarks) private import QPACK

// QPACK isn't a library product, so add entry points for benchmarks here under SPI.
@_spi(Benchmarks)
public enum QPACKBenchmarks {
    /// Encode `headers` with the static table encoder. Returns the number of field lines
    /// produced.
    ///
    /// The return value doesn't matter, but needs to be there so the calling benchmark
    /// can stop the function call from being optimised away.
    @_spi(Benchmarks)
    public static func staticEncode(headers: [HTTPField]) -> Int {
        let encoder = QPACKEncoder()
        return encoder.encode(headers: headers).lines.count
    }
}
