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

package import NIOQUICHelpers

/// Keeps track of what streams are open.
@available(anyAppleOS 26, *)
package struct StreamIDTracker {
    /// All currently open streams
    private(set) var openStreams = Set<QUICStreamID>()

    /// The number of currently open bidirectional ("request") streams, regardless of initiator.
    /// Maintained incrementally so ``hasOpenRequestStreams()`` is O(1) instead of scanning ``openStreams``.
    private var openBidirectionalStreamCount = 0

    /// We store the highest id we've ever seen for each type of stream. When we see a new id, we store it at index calculated by taking the last 2 bits of the id.
    /// The last 2 bits are what determine the type, see RFC 9000 § 2.1.
    /// So index 0 is client-initiated bidi, index 1 is server-initiated bidi, index 2 is client-initiated uni and index 3 is server-initiated uni.
    private var highestIDSeenByType: InlineArray<4, QUICStreamID?> = [nil, nil, nil, nil]

    package init() {}

    /// Call this whenever a new stream (of any type) opens.
    package mutating func streamOpened(id: QUICStreamID) {
        assert(!self.openStreams.contains(id))
        self.openStreams.insert(id)

        if id.isBidirectional {
            self.openBidirectionalStreamCount += 1
        }

        let streamType = Int(id.rawValue & 0b11)  // The last 2 bits determine the type of a QUIC stream.

        let previousHighestSeenID = self.highestIDSeenByType[streamType]
        if previousHighestSeenID == nil || id > previousHighestSeenID! {
            self.highestIDSeenByType[streamType] = id
        }
    }

    /// Call this when a stream is closed. Returns true if that stream actually existed.
    @discardableResult
    package mutating func streamClosed(id: QUICStreamID) -> Bool {
        if self.openStreams.remove(id) == nil {
            return false
        }
        if id.isBidirectional {
            self.openBidirectionalStreamCount -= 1
        }
        return true
    }

    /// - Returns: `true` if there are any open bidirectional streams, regardless of initiator
    package func hasOpenRequestStreams() -> Bool {
        self.openBidirectionalStreamCount > 0
    }

    package func getOpenStreamIDs(where predicate: (QUICStreamID) -> Bool) -> [QUICStreamID] {
        self.openStreams.filter(predicate)
    }

    /// Returns the next expected client-initiated bidirectional stream ID, i.e. the stream ID that *would* be used by
    /// the next client request stream opened on this connection.
    ///
    /// If no client-initiated bidirectional streams have been received yet, returns stream ID 0, the lowest possible
    /// client-initiated bidirectional stream ID.
    package func nextExpectedClientInitiatedBidirectionalStreamID() -> QUICStreamID {
        // Index 0 represents client-initiated bidirectional streams in `self.highestIDSeenByType`.
        if let highest = self.highestIDSeenByType[0] {
            return QUICStreamID(rawValue: highest.rawValue + 4)
        }

        return QUICStreamID(rawValue: 0)
    }

    /// - Returns: `true` if the next id of the same type as the provided one would be equal to or greater than the provided one.
    package func hasExhaustedSameTypeStreams(withIDsLessThan givenID: QUICStreamID) -> Bool {
        /// The stream type for the id we were given. This is determined by the last 2 bits. See RFC 9000 § 2.1
        let givenIDType = Int(givenID.rawValue & 0b11)
        /// The highest ID that we have seen so far for streams of this type
        let highestSeenIDOfSameType = self.highestIDSeenByType[givenIDType]
        /// The next ID for a stream of this type
        let nextIDOfSameType =
            if let highestSeenIDOfSameType {
                highestSeenIDOfSameType.rawValue + 4
            } else {
                /// We haven't seen one, so we want to know the first possible ID for a stream of this type. That is actually the type itself
                UInt64(givenIDType)
            }
        // Would the next ID be more than or equal to the max?
        return nextIDOfSameType >= givenID.rawValue
    }
}
