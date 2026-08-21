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

import DequeModule
@_spi(PackageInternal) import HTTP3

/// State machine used by the handler which is on the outbound control stream.
struct HTTP3OutboundControlStreamStateMachine: ~Copyable {
    private enum State: ~Copyable {
        /// The handler isn't active yet. Any frame which we have tried to send so far gets buffered here.
        /// The first of those should be the settings.
        case inactive(buffer: Deque<HTTP3Frame>)
        /// The handler is now active. Any further frames should be sent without buffering.
        case active
    }

    private let state: State

    init(settings: HTTP3Settings) {
        // First frame must always be settings
        self.init(state: .inactive(buffer: [.settings(settings)]))
    }

    private init(state: consuming State) {
        self.state = state
    }

    enum ChannelActiveAction: Hashable, Sendable {
        case sendFrames(Deque<HTTP3Frame>)
    }

    mutating func channelActive() -> ChannelActiveAction? {
        switch consume self.state {
        case .inactive(let buffer):
            self = .init(state: .active)
            return .sendFrames(buffer)
        case .active:
            fatalError("Channel active called twice")
        }
    }

    enum SendGoawayAction: Hashable, Sendable {
        case send
    }

    mutating func sendGoaway(id: HTTP3GoawayID) -> SendGoawayAction? {
        switch consume self.state {
        case .inactive(var buffer):
            // We're not active yet so we have to buffer the goaway (behind the settings, and any other goaways)
            buffer.append(.goaway(id))
            self = .init(state: .inactive(buffer: buffer))
            return .none
        case .active:
            self = .init(state: .active)
            return .send
        }
    }
}
