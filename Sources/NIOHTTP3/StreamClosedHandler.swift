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

import Logging
import NIOCore

struct StreamClosedHandlerStateMachine: ~Copyable {
    private enum State: ~Copyable {
        // We have never been active.
        case notActive
        // We are currently active.
        case active
        // The channel became inactive and/or the handler was removed.
        case finished
    }

    private var state: State

    private init(state: consuming State) {
        self.state = state
    }

    init() {
        self.init(state: .notActive)
    }

    enum ChannelInactiveAction: Hashable {
        case callOnStreamClosed
        case none
    }

    mutating func channelInactive() -> ChannelInactiveAction {
        switch consume self.state {
        case .active:
            // We were active and now we're not, so we're closed.
            self = .init(state: .finished)
            return .callOnStreamClosed
        case .finished:
            self = .init(state: .finished)
            return .none
        case .notActive:
            // There apparently is a bug in NIO where this can (rarely) happen. In those cases, we should just finish.
            self = .init(state: .finished)
            return .callOnStreamClosed
        }
    }

    mutating func handlerAdded(isChannelActive: Bool) {
        switch consume self.state {
        case .active:
            assertionFailure("Handler added after channel active")
            self = .init(state: .active)
        case .notActive:
            if isChannelActive {
                self = .init(state: .active)
            } else {
                self = .init(state: .notActive)
            }
        case .finished:
            assertionFailure("Handler added after inactive")
            self = .init(state: .finished)
        }
    }

    mutating func channelActive() {
        switch consume self.state {
        case .active:
            assertionFailure("Handler active twice")
            self = .init(state: .active)
        case .notActive:
            self = .init(state: .active)
        case .finished:
            assertionFailure("Handler active after inactive")
            self = .init(state: .finished)
        }
    }

    enum HandlerRemovedAction: Hashable {
        case callOnStreamClosed
        case none
    }

    mutating func handlerRemoved() -> HandlerRemovedAction {
        switch consume self.state {
        case .notActive:
            // We were never active, and we've been removed, so we're 'closed'.
            // This can happen if the connection was closed during stream initialization.
            self = .init(state: .finished)
            return .callOnStreamClosed
        case .finished:
            self = .init(state: .finished)
            return .none
        case .active:
            assertionFailure("Handler removed whilst active")
            self = .init(state: .active)
            return .none
        }
    }
}

/// Waits for the channel to become inactive, or this handler to be removed, then calls a closure.
final class StreamClosedHandler: ChannelInboundHandler {
    typealias InboundIn = Never

    private var stateMachine = StreamClosedHandlerStateMachine()
    private var onStreamClosed: () -> Void

    init(onStreamClosed: @escaping () -> Void) {
        self.onStreamClosed = onStreamClosed
    }

    func channelInactive(context: ChannelHandlerContext) {
        switch self.stateMachine.channelInactive() {
        case .callOnStreamClosed:
            self.onStreamClosed()
        case .none:
            break
        }
        context.fireChannelInactive()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.stateMachine.handlerAdded(isChannelActive: context.channel.isActive)
    }

    func channelActive(context: ChannelHandlerContext) {
        self.stateMachine.channelActive()
        context.fireChannelActive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        switch self.stateMachine.handlerRemoved() {
        case .callOnStreamClosed:
            self.onStreamClosed()
        case .none:
            break
        }
    }
}
