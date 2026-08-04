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

import Benchmark
import HTTPTypes
@_spi(Benchmarks) import NIOHTTP3
import NIOQUICHelpers

/// A realistic request header set for a browser GET, exercising a mix of exact
/// static-table matches (`:method GET`), name-only matches (`:authority`) and
/// headers absent from the table (`x-custom-header`).
private let requestHeaders: [HTTPField] = [
    HTTPField(name: .init(parsed: ":method")!, value: "GET"),
    HTTPField(name: .init(parsed: ":scheme")!, value: "https"),
    HTTPField(name: .init(parsed: ":authority")!, value: "www.example.com"),
    HTTPField(name: .init(parsed: ":path")!, value: "/index.html"),
    HTTPField(name: .init(parsed: "user-agent")!, value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
    HTTPField(name: .init(parsed: "accept")!, value: "*/*"),
    HTTPField(name: .init(parsed: "accept-encoding")!, value: "gzip, deflate, br"),
    HTTPField(name: .init(parsed: "accept-language")!, value: "en-US,en;q=0.9"),
    HTTPField(name: .init(parsed: "cache-control")!, value: "no-cache"),
    HTTPField(name: .init(parsed: "cookie")!, value: "session=abc123def456; theme=dark"),
    HTTPField(name: .init(parsed: "referer")!, value: "https://www.example.com/"),
    HTTPField(name: .init(parsed: "x-custom-header")!, value: "some-custom-value"),
]

let benchmarks: @Sendable () -> Void = {
    // Exercises StaticHeaderTable.find on every header, with no dynamic table.
    Benchmark(
        "QPACKStaticEncode_BrowserGET",
        configuration: .init(
            metrics: [.mallocCountTotal, .instructions, .wallClock],
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(QPACKBenchmarks.staticEncode(headers: requestHeaders))
        }
    }

    // Exercises the static-table lookup plus the dynamic table on every header.
    Benchmark(
        "QPACKDynamicEncode_BrowserGET",
        configuration: .init(
            metrics: [.mallocCountTotal, .instructions, .wallClock],
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(
                QPACKBenchmarks.dynamicEncode(
                    headers: requestHeaders,
                    streamID: QUICStreamID(rawValue: 0),
                    dynamicTableMaxCapacity: 4096,
                    dynamicTableInitialCapacity: 4096,
                    maxBlockedStreams: 100,
                    targetEvictableFraction: 0.5
                )
            )
        }
    }
}
