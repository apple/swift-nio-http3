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

var swiftSettings: [PackageDescription.SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableExperimentalFeature("AnyAppleOSAvailability"),
]

let package = Package(
    name: "swift-nio-http3",
    products: [
        .library(name: "NIOHTTP3", targets: ["NIOHTTP3"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0-beta.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.3"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/apple/swift-nio-quic-helpers.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/apple/swift-nio-quic.git", .upToNextMinor(from: "0.1.0")),
    ],
    targets: [
        .target(
            name: "HTTP3",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOQUICHelpers", package: "swift-nio-quic-helpers"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "HeapModule", package: "swift-collections"),
                .target(name: "QPACK"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOHTTP3",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOQUICHelpers", package: "swift-nio-quic-helpers"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
                .target(name: "HTTP3"),
                .target(name: "QPACK"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "QPACK",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOQUICHelpers", package: "swift-nio-quic-helpers"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HTTP3Tests",
            dependencies: [
                .target(name: "HTTP3"),
                .target(name: "QPACK"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOHTTP3Tests",
            dependencies: [
                .target(name: "HTTP3"),
                .target(name: "NIOHTTP3"),
                .target(name: "QPACK"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTestUtils", package: "swift-nio"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "QPACKTests",
            dependencies: [
                .target(name: "QPACK"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "H3IntegrationTests",
            dependencies: [
                .target(name: "HTTP3"),
                .target(name: "NIOHTTP3"),
                .target(name: "QPACK"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOQUICHelpers", package: "swift-nio-quic-helpers"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "NIOQUIC", package: "swift-nio-quic"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
