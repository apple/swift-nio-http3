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

@_spi(PackageInternal) import HTTP3
import Testing

@testable import NIOHTTP3

struct HTTP3OutboundControlStreamStateMachineTests {
    @Test
    func channelActive() {
        let testSettings = HTTP3Settings()
        var stateMachine = HTTP3OutboundControlStreamStateMachine(settings: testSettings)
        let action = stateMachine.channelActive()
        #expect(action == .sendFrames([.settings(testSettings)]))
    }

    @Test
    func goawayAfterChannelActive() {
        let testSettings = HTTP3Settings()
        var stateMachine = HTTP3OutboundControlStreamStateMachine(settings: testSettings)

        let action1 = stateMachine.channelActive()
        #expect(action1 == .sendFrames([.settings(testSettings)]))

        let action2 = stateMachine.sendGoaway(id: 10)
        #expect(action2 == .send)
    }

    @Test
    func goawayBeforeChannelActive() {
        let testSettings = HTTP3Settings()
        var stateMachine = HTTP3OutboundControlStreamStateMachine(settings: testSettings)

        let action1 = stateMachine.sendGoaway(id: 10)
        #expect(action1 == .none)

        let action2 = stateMachine.channelActive()
        #expect(action2 == .sendFrames([.settings(testSettings), .goaway(10)]))
    }
}
