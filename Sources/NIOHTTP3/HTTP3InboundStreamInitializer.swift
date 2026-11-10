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

public import NIOCore

/// Sets up the inbound streams of an HTTP/3 connection: request streams for servers, and push streams for clients.
///
/// ``initialize(_:)`` is called with each new inbound stream. When the connection becomes inactive, ``finish()`` is
/// called to signal that no more streams will arrive.
@available(anyAppleOS 27, *)
public protocol HTTP3InboundStreamInitializerProtocol: SendableMetatype {
    /// Called with each new inbound stream channel, before the channel is activated.
    ///
    /// - Parameter parameters: The new stream channel and its stream ID.
    /// - Returns: A future which completes once the stream channel has been initialized.
    func initialize(_ parameters: HTTP3StreamInitializerParameters) -> EventLoopFuture<Void>

    /// Called once the connection has become inactive.
    func finish()
}

/// Calls a closure with each new inbound stream channel.
@available(anyAppleOS 27, *)
public struct HTTP3InboundStreamInitializer: HTTP3InboundStreamInitializerProtocol {
    private let initializer: (HTTP3StreamInitializerParameters) -> EventLoopFuture<Void>

    /// Create a new ``HTTP3InboundStreamInitializer``.
    /// - Parameter initializer: Called with each new inbound stream channel.
    public init(_ initializer: @escaping (HTTP3StreamInitializerParameters) -> EventLoopFuture<Void>) {
        self.initializer = initializer
    }

    public func initialize(_ parameters: HTTP3StreamInitializerParameters) -> EventLoopFuture<Void> {
        self.initializer(parameters)
    }

    public func finish() {}
}

/// Yields the output of a stream initializer to an `AsyncStream`. Finishes the `AsyncStream` once the connection has
/// become inactive.
@_spi(HTTP3AsyncInterface)
@available(anyAppleOS 27, *)
public struct HTTP3AsyncInboundStreamInitializer<Output: Sendable>: HTTP3InboundStreamInitializerProtocol, Sendable {
    private let continuation: AsyncStream<Output>.Continuation
    private let streamInitializer: @Sendable (HTTP3StreamInitializerParameters) -> EventLoopFuture<Output>

    init(
        yieldingTo continuation: AsyncStream<Output>.Continuation,
        streamInitializer: @escaping @Sendable (HTTP3StreamInitializerParameters) -> EventLoopFuture<Output>
    ) {
        self.continuation = continuation
        self.streamInitializer = streamInitializer
    }

    public func initialize(_ parameters: HTTP3StreamInitializerParameters) -> EventLoopFuture<Void> {
        self.streamInitializer(parameters).map { output in
            switch self.continuation.yield(output) {
            case .enqueued:
                ()

            // Close the stream channel if the yield was not successful.
            case .dropped, .terminated:
                parameters.channel.close(promise: nil)

            @unknown default:
                parameters.channel.close(promise: nil)
            }
        }
    }

    public func finish() {
        self.continuation.finish()
    }
}
