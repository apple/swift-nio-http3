# SwiftNIO HTTP/3

SwiftNIO HTTP/3 provides an implementation of the HTTP/3 protocol. You can
use it with [SwiftNIO QUIC][swift-nio-quic] and [SwiftNIO][swift-nio] to create
HTTP/3 clients and servers.

> [!IMPORTANT]
> This package is still in active development and does not offer a stable API
> yet.

## Quick Start

The following snippet contains a Swift Package manifest to use SwiftNIO HTTP/3
with SwiftNIO QUIC.

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Application",
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(url: "https://github.com/apple/swift-nio-http3", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio-quic", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "H3Server",
            dependencies: [
                .product(name: "NIOQUIC", package: "swift-nio-quic"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP3", package: "swift-nio-http3"),
            ]
        )
    ]
)
```

## Getting Started

### Prerequisites

- [Swift 6.3 and up](https://swift.org/install)
- macOS 26.0 and up or Linux (Ubuntu 22.04+)
- Xcode 26.0 and up (Apple platforms only)

### Building and testing

Packages in the dependency tree depend on a beta release of swift-crypto.
Set the environment variable
`SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA` to allow swift-certificates
(in the dependency tree) to adopt swift-crypto beta releases as well.

To build via the command line (for all platforms), run at the root of the
package:

```
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift build
```

To run all unit tests, run

```
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift test
```

Unit tests can also be run by filtering a specific class or function:

```
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift test --filter EncoderTests
SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift test --filter EncoderTests.maxBlockedStreams
```

Use `SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 xed Package.swift` to open
the project in Xcode with the environment variable set.

[swift-nio-quic]: https://github.com/apple/swift-nio-quic
[swift-nio]: https://github.com/apple/swift-nio
