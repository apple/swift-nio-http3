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

import NIOQUICHelpers
@_spi(PackageInternal) import QPACK
import Testing

@_spi(PackageInternal) @testable import HTTP3

struct FieldSectionQueueTests {
    private func makeTestEntry(streamID: QUICStreamID, requiredInsertCount: Int) -> FieldSectionQueue.Entry {
        let prefix = FieldSectionPrefix(requiredInsertCount: requiredInsertCount, base: 0)
        return FieldSectionQueue.Entry(
            headers: .init(fieldSection: .init(prefix: prefix.encode(maxCapacity: 100), lines: [])),
            prefix: prefix,
            lines: [],
            streamID: streamID
        )
    }

    @Test
    func cantAddMoreThanMaxItems() throws {
        var queue = FieldSectionQueue(maxItems: 3)

        try queue.add(self.makeTestEntry(streamID: 1, requiredInsertCount: 1))
        try queue.add(self.makeTestEntry(streamID: 2, requiredInsertCount: 1))
        try queue.add(self.makeTestEntry(streamID: 3, requiredInsertCount: 1))
        // 4th item fails, because max is 3
        #expect(throws: FieldSectionQueueError.reachedMaxSize) {
            try queue.add(self.makeTestEntry(streamID: 4, requiredInsertCount: 1))
        }
    }

    @Test
    func popsNothingIfNothingDecodable() throws {
        var queue = FieldSectionQueue(maxItems: 3)

        try queue.add(self.makeTestEntry(streamID: 1, requiredInsertCount: 10))
        try queue.add(self.makeTestEntry(streamID: 2, requiredInsertCount: 20))

        #expect(queue.popIfDecodable(availableInsertCount: 5) == nil)
    }

    @Test
    func popsOldestIfMultipleDecodable() throws {
        var queue = FieldSectionQueue(maxItems: 3)

        try queue.add(self.makeTestEntry(streamID: 1, requiredInsertCount: 40))
        try queue.add(self.makeTestEntry(streamID: 2, requiredInsertCount: 10))
        try queue.add(self.makeTestEntry(streamID: 3, requiredInsertCount: 20))

        #expect(queue.popIfDecodable(availableInsertCount: 30)?.streamID == 2)
        #expect(queue.popIfDecodable(availableInsertCount: 30)?.streamID == 3)
        #expect(queue.popIfDecodable(availableInsertCount: 30) == nil)
        #expect(queue.popIfDecodable(availableInsertCount: 40)?.streamID == 1)
        #expect(queue.popIfDecodable(availableInsertCount: 40) == nil)
    }

    @Test
    func removesEntries() throws {
        var queue = FieldSectionQueue(maxItems: 3)

        try queue.add(self.makeTestEntry(streamID: 1, requiredInsertCount: 40))
        try queue.add(self.makeTestEntry(streamID: 2, requiredInsertCount: 10))
        try queue.add(self.makeTestEntry(streamID: 3, requiredInsertCount: 20))

        // We have 3 entries, until we remove one, and then we have 2
        #expect(queue._allEntries.count == 3)
        queue.removeAll(forStream: 2)
        #expect(queue._allEntries.count == 2)

        // Removing again has no effect
        queue.removeAll(forStream: 2)
        #expect(queue._allEntries.count == 2)
    }
}
