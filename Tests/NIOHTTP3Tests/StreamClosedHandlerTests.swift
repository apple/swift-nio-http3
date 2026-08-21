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

import Testing

@testable import NIOHTTP3

struct StreamClosedHandlerTests {
    @Test
    func testActiveThenInactive() throws {
        var stateMachine = StreamClosedHandlerStateMachine()
        stateMachine.channelActive()
        #expect(stateMachine.channelInactive() == .callOnStreamClosed)
        #expect(stateMachine.channelInactive() == .none)
    }

    @Test
    func testAddOnActiveChannelThenInactive() throws {
        var stateMachine = StreamClosedHandlerStateMachine()
        stateMachine.handlerAdded(isChannelActive: true)
        #expect(stateMachine.channelInactive() == .callOnStreamClosed)
        #expect(stateMachine.channelInactive() == .none)
    }

    @Test
    func testAddOnInctiveChannelThenActiveThenInactive() throws {
        var stateMachine = StreamClosedHandlerStateMachine()
        stateMachine.handlerAdded(isChannelActive: false)
        stateMachine.channelActive()
        #expect(stateMachine.channelInactive() == .callOnStreamClosed)
        #expect(stateMachine.channelInactive() == .none)
    }

    @Test
    func testAddAndRemoveOnInactiveChannel() throws {
        var stateMachine = StreamClosedHandlerStateMachine()
        stateMachine.handlerAdded(isChannelActive: false)
        #expect(stateMachine.handlerRemoved() == .callOnStreamClosed)
        #expect(stateMachine.handlerRemoved() == .none)
    }

    @Test
    func testInactiveBeforeActive() throws {
        var stateMachine = StreamClosedHandlerStateMachine()
        #expect(stateMachine.channelInactive() == .callOnStreamClosed)
        #expect(stateMachine.channelInactive() == .none)
    }
}
