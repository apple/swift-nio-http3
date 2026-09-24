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

final class ErrorCatchingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Never
    typealias OutboundIn = Never

    let errorPromise: EventLoopPromise<any Error>

    init(errorPromise: EventLoopPromise<any Error>) {
        self.errorPromise = errorPromise
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.errorPromise.fail(NeverFulfilled())
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.errorPromise.succeed(error)
        context.fireErrorCaught(error)
    }
}

extension HTTP3Settings {
    static let forTestingWithDynamicTable: Self = HTTP3Settings(
        qpackMaximumTableCapacity: 1024,
        qpackBlockedStreams: 10
    )
}

extension HTTP3GoawayID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}
