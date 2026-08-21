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

@testable import HTTP3

struct StreamIDTrackerTests {
    @Test
    func testIDsUnique() {
        // Test add IDs
        var tracker = StreamIDTracker()
        for i: UInt64 in 0..<1000 {
            tracker.streamOpened(id: .init(rawValue: i))
        }
        for i: UInt64 in 0..<1000 {
            let existed = tracker.streamClosed(id: .init(rawValue: i))
            #expect(existed)
        }
    }

    @Test
    func testCloseNonExistentStream() {
        var tracker = StreamIDTracker()
        let existed = tracker.streamClosed(id: 123)
        #expect(!existed)
    }

    @Test
    func testHasOpenRequestStreams() {
        var tracker = StreamIDTracker()
        tracker.streamOpened(id: 0)

        #expect(tracker.hasOpenRequestStreams())

        tracker.streamClosed(id: 0)
        #expect(!tracker.hasOpenRequestStreams())
    }

    @Test
    func testHasExhaustedStreamsWhenEmpty() {
        let tracker = StreamIDTracker()
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 0))
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 1))
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 2))
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 3))

        #expect(!tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 4))
        #expect(!tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 5))
        #expect(!tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 6))
        #expect(!tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 7))
    }

    @Test
    func testHasExhaustedStreamsWhenNotEmpty() {
        var tracker = StreamIDTracker()
        tracker.streamOpened(id: 0)
        tracker.streamOpened(id: 13)

        // These are the same type as 0
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 0))
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 4))
        #expect(!tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 8))

        // These are the same type as 13
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 1))
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 5))
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 9))
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 13))
        #expect(tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 17))
        #expect(!tracker.hasExhaustedSameTypeStreams(withIDsLessThan: 21))
    }

    @Test
    func testGetStreamsMatchingPredicate() {
        var tracker = StreamIDTracker()
        tracker.streamOpened(id: 0)
        tracker.streamOpened(id: 13)

        #expect(tracker.getOpenStreamIDs { $0 == 0 } == [0])
        #expect(tracker.getOpenStreamIDs { $0 == 13 } == [13])
        #expect(tracker.getOpenStreamIDs { $0 < 20 }.sorted() == [0, 13])
        #expect(tracker.getOpenStreamIDs { $0.isClientInitiated }.sorted() == [0])
    }

    @Test
    func nextExpectedReturnsZeroWhenNoStreamsReceived() {
        let tracker = StreamIDTracker()
        // No streams have been received, so the next expected client-initiated bidi stream is 0.
        #expect(tracker.nextExpectedClientInitiatedBidirectionalStreamID() == .init(rawValue: 0))
    }

    @Test
    func nextExpectedAfterSingleStream() {
        var tracker = StreamIDTracker()
        // Client-initiated bidi stream 0 received.
        tracker.streamOpened(id: .init(rawValue: 0))
        // Next expected is 4 (IDs within a type are spaced 4 apart).
        #expect(tracker.nextExpectedClientInitiatedBidirectionalStreamID() == .init(rawValue: 4))
    }

    @Test
    func nextExpectedAfterMultipleStreams() {
        var tracker = StreamIDTracker()
        // Client-initiated bidi streams: 0, 4, 8
        tracker.streamOpened(id: .init(rawValue: 0))
        tracker.streamOpened(id: .init(rawValue: 4))
        tracker.streamOpened(id: .init(rawValue: 8))
        #expect(tracker.nextExpectedClientInitiatedBidirectionalStreamID() == .init(rawValue: 12))
    }

    @Test
    func nextExpectedUnaffectedByStreamClosures() {
        var tracker = StreamIDTracker()
        tracker.streamOpened(id: .init(rawValue: 0))
        tracker.streamOpened(id: .init(rawValue: 4))
        // Closing streams doesn't change the highest seen ID.
        tracker.streamClosed(id: .init(rawValue: 4))
        tracker.streamClosed(id: .init(rawValue: 0))
        #expect(tracker.nextExpectedClientInitiatedBidirectionalStreamID() == .init(rawValue: 8))
    }
}
