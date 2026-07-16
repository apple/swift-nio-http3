// swift-tools-version:6.3
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

import PackageDescription

let package = Package(
    name: "swift-nio-http3-benchmarks",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio-quic-helpers.git", branch: "main"),
        .package(url: "https://github.com/ordo-one/benchmark.git", from: "1.35.0"),
    ],
    targets: [
        .executableTarget(
            name: "QPACKBenchmarks",
            dependencies: [
                .product(name: "NIOHTTP3", package: "swift-nio-http3"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOQUICHelpers", package: "swift-nio-quic-helpers"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "QPACKBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark")
            ]
        )
    ]
)
