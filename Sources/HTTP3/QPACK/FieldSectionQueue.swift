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

import HeapModule
package import NIOQUICHelpers
package import QPACK

package enum FieldSectionQueueError: Error, Hashable, Sendable {
    case reachedMaxSize
}

/// A queue of FieldSections which cannot yet be decoded.
struct FieldSectionQueue {
    /// An entry in the queue.
    /// `Comparable` and `Equatable` are implemented based on the ``FieldSectionPrefix/requiredInsertCount`` only.
    struct Entry: Sendable, Comparable {
        /// The original full headers.
        var headers: HTTP3PartialFrame.Headers
        /// The prefix of the message to be decoded.
        var prefix: FieldSectionPrefix
        /// The field lines to decode.
        var lines: [FieldLine]
        /// The id of the stream we received this message on.
        var streamID: QUICStreamID

        init(
            headers: HTTP3PartialFrame.Headers,
            prefix: FieldSectionPrefix,
            lines: [FieldLine],
            streamID: QUICStreamID
        ) {
            self.headers = headers
            self.prefix = prefix
            self.lines = lines
            self.streamID = streamID
        }

        static func < (lhs: Entry, rhs: Entry) -> Bool {
            lhs.prefix.requiredInsertCount < rhs.prefix.requiredInsertCount
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.prefix.requiredInsertCount == rhs.prefix.requiredInsertCount
        }
    }

    /// The maximum number of items that may be in the queue at any one time.
    private let maxItems: Int
    /// The items in the queue. Ordered by required insert count.
    private var entries: Heap<Entry> = .init()

    /// Exposed for testing. A list of all the entries in the queue. Not in any particular order.
    package var _allEntries: [Entry] {
        self.entries.unordered
    }

    /// Pop an entry with a required insert count ≤ `availableInsertCount`, if any such entry exists.
    mutating func popIfDecodable(availableInsertCount: Int) -> Entry? {
        guard let nextItem = entries.min, nextItem.prefix.requiredInsertCount <= availableInsertCount else {
            return nil
        }
        // Safe to unwrap, because of guard above
        return self.entries.popMin()!
    }

    /// Add an entry to the queue.
    mutating func add(_ entry: Entry) throws(FieldSectionQueueError) {
        if self.entries.count == self.maxItems {
            throw FieldSectionQueueError.reachedMaxSize
        }
        // It should not be possible for multiple headers to get enqueued by the same stream
        // Because a stream should block any further frames coming in behind the header it is waiting for
        assert(!self.entries.unordered.contains { $0.streamID == entry.streamID })
        self.entries.insert(entry)
    }

    /// Remove all entries in the queue which correspond to the given streamID.
    mutating func removeAll(forStream streamID: QUICStreamID) {
        // Fairly expensive operation, but only called when a stream closes uncleanly, which should be rare.
        // Also, this heap should never be very big anyway, at most equal to the number of open streams.
        self.entries = .init(self.entries.unordered.filter { $0.streamID != streamID })
    }

    /// - Parameter maxItems: The maximum number of items that may be in the queue at any one time.
    init(maxItems: Int) {
        self.maxItems = maxItems
    }
}
