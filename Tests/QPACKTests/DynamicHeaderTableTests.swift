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

import HTTPTypes
import NIOCore
import Testing

@testable import QPACK

struct DynamicHeaderTableTests {
    @Test
    func findByName() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 1024,
            initialCapacity: 1024,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        try table.addHeader(named: "Test", value: "1")
        let result = table.findExistingHeader(named: "Test", value: nil)
        #expect(result?.relativeIndex == 0)
        #expect(result?.containsValue == false)
        guard let index = result?.relativeIndex else {
            Issue.record("No result")
            return
        }
        let entry = table.get(relativeIndex: index)
        #expect(entry?.name.canonicalName == "test")
        #expect(entry?.value == "1")
        #expect(entry?.absoluteIndex == 0)
    }

    @Test
    func findByNameAndValue() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 1024,
            initialCapacity: 1024,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        try table.addHeader(named: "Test", value: "1")
        let result = table.findExistingHeader(named: "Test", value: "1")
        #expect(result?.relativeIndex == 0)
        #expect(result?.containsValue == true)
        guard let index = result?.relativeIndex else {
            Issue.record("No result")
            return
        }
        let entry = table.get(relativeIndex: index)
        #expect(entry?.name.canonicalName == "test")
        #expect(entry?.value == "1")
        #expect(entry?.absoluteIndex == 0)
    }

    @Test
    func findByNameAndValueDoesntExist() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 1024,
            initialCapacity: 1024,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        try table.addHeader(named: "Test", value: "1")
        try table.addHeader(named: "bla", value: "1")
        let result = table.findExistingHeader(named: "Test", value: "2")
        #expect(result?.relativeIndex == 1)
        #expect(result?.containsValue == false)
        guard let index = result?.relativeIndex else {
            Issue.record("No result")
            return
        }
        let entry = table.get(relativeIndex: index)
        #expect(entry?.name.canonicalName == "test")
        #expect(entry?.value == "1")
        #expect(entry?.absoluteIndex == 0)
    }

    @Test
    func findByNameDoesntExist() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 1024,
            initialCapacity: 1024,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        try table.addHeader(named: "Test", value: "1")
        let result = table.findExistingHeader(named: "bla", value: nil)
        #expect(result == nil)
    }

    @Test
    func absoluteIndex() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 1024,
            initialCapacity: 1024,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        for absoluteIndex in 0...10 {
            try table.addHeader(named: "name\(absoluteIndex)", value: "value\(absoluteIndex)")
        }
        for relativeIndex in 0...10 {
            // Indexing by relative index should be in reverse order to absolute index
            let entry = table.get(relativeIndex: relativeIndex)
            let absoluteIndex = 10 - relativeIndex
            #expect(entry?.name.canonicalName == "name\(absoluteIndex)")
            #expect(entry?.value == "value\(absoluteIndex)")
            #expect(entry?.absoluteIndex == absoluteIndex)
            let entryByAbsolute = table.get(absoluteIndex: absoluteIndex)
            #expect(entry == entryByAbsolute)
        }
    }

    @Test
    func getOutOfBounds() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 1024,
            initialCapacity: 1024,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        for absoluteIndex in 0...10 {
            try table.addHeader(named: "name\(absoluteIndex)", value: "value\(absoluteIndex)")
        }
        #expect(table.get(relativeIndex: -1) == nil)
        #expect(table.get(relativeIndex: 11) == nil)
        #expect(table.get(absoluteIndex: -1) == nil)
        #expect(table.get(absoluteIndex: 11) == nil)
    }

    @Test
    func getOutOfBoundsAfterEviction() throws {
        // Set the capacity to only fit 4
        let lengthOfEntry = "name1".count + "value1".count + 32
        var table = DynamicHeaderTable(
            maximumCapacity: lengthOfEntry * 4,
            initialCapacity: lengthOfEntry * 4,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        // We insert items 0,1,2,3,5 (6 items in total) but can only fit 4
        for absoluteIndex in 0...5 {
            try table.addHeader(named: "name\(absoluteIndex)", value: "value\(absoluteIndex)")
        }
        // Expected final state
        // | absolute index | relative index | name  | value  |
        // | 2              | 3              | name2 | value2 |
        // | 3              | 2              | name3 | value3 |
        // | 4              | 1              | name4 | value4 |
        // | 5              | 0              | name5 | value5 |
        #expect(table.get(relativeIndex: -1) == nil)
        #expect(table.get(relativeIndex: 4) == nil)
        #expect(table.get(absoluteIndex: -1) == nil)
        #expect(table.get(absoluteIndex: 0) == nil)
        #expect(table.get(absoluteIndex: 1) == nil)
        #expect(table.get(absoluteIndex: 6) == nil)
    }

    @Test
    func maximumCapacity() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 70,
            initialCapacity: 70,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )

        // added 34 bytes
        try table.addHeader(named: "a", value: "1")
        // added 34 bytes
        try table.addHeader(named: "b", value: "2")
        // adding 34 bytes again would take us over the limit, so oldest entry should get evicted
        try table.addHeader(named: "c", value: "3")

        // Should now see c and b only
        let indexA = table.findExistingHeader(named: "a", value: nil)
        let indexB = table.findExistingHeader(named: "b", value: nil)
        let indexC = table.findExistingHeader(named: "c", value: nil)
        #expect(indexA == nil)
        #expect(indexB?.relativeIndex == 1)
        #expect(indexC?.relativeIndex == 0)

        guard let indexB, let indexC else {
            Issue.record("Unexpected nil")
            return
        }
        let entryB = table.get(relativeIndex: indexB.relativeIndex)
        let entryC = table.get(relativeIndex: indexC.relativeIndex)
        #expect(entryB?.name.canonicalName == "b")
        #expect(entryB?.absoluteIndex == 1)
        #expect(entryB?.value == "2")
        #expect(entryC?.name.canonicalName == "c")
        #expect(entryC?.absoluteIndex == 2)
        #expect(entryC?.value == "3")
    }

    @Test
    func maxCapacityOfZero() {
        var table = DynamicHeaderTable(
            maximumCapacity: 0,
            initialCapacity: 0,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )

        // Adding anything is impossible
        #expect(throws: HeaderTableError.insufficientStorage) {
            try table.addHeader(named: "a", value: "1")
        }
    }

    @Test
    func tooLargeKeepOld() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 35,
            initialCapacity: 35,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )

        // added 34 bytes
        try table.addHeader(named: "a", value: "1")
        // Adding this (36 bytes) is impossible, because we cannot clear enough room
        #expect(throws: HeaderTableError.insufficientStorage) {
            try table.addHeader(named: "aa", value: "11")
        }
        // Should retain the original entry
        let indexA = table.findExistingHeader(named: "a", value: nil)
        #expect(indexA?.relativeIndex == 0)
    }

    @Test
    func insertCountIncrement() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 100,
            initialCapacity: 100,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        // insert count is 0, so we can't increment the known received count
        #expect(throws: DynamicHeaderTableError.incrementTooHigh) {
            try table.insertCountIncrement(by: 1)
        }
        // add an item
        try table.addHeader(named: "Test", value: "test")
        // Increment by 0 always invalid
        #expect(throws: DynamicHeaderTableError.incrementTooLow) {
            try table.insertCountIncrement(by: 0)
        }
        // Increment by one is now valid
        try table.insertCountIncrement(by: 1)
        // Increment by one more is invalid
        #expect(throws: DynamicHeaderTableError.incrementTooHigh) {
            try table.insertCountIncrement(by: 1)
        }
    }

    @Test
    func insertCountIncrementOverflow() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 100,
            initialCapacity: 100,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        // add an item
        try table.addHeader(named: "Test", value: "test")

        // Increment by one is valid
        try table.insertCountIncrement(by: 1)
        // Any further increment is invalid because there's only one insert.
        // Use Int.max to ensure we don't overflow the tables internal representation of the insert count.
        #expect(throws: DynamicHeaderTableError.incrementTooHigh) {
            try table.insertCountIncrement(by: Int.max)
        }
    }

    @Test
    func acknowledgeInsertCount() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 100,
            initialCapacity: 100,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        // insert count is 0, so we can't ack 1 or more
        #expect(throws: DynamicHeaderTableError.ackCountTooHigh) {
            try table.acknowledgeInsertCount(1)
        }
        // add an item
        try table.addHeader(named: "test", value: "test")
        // Ack 0 always invalid
        #expect(throws: DynamicHeaderTableError.ackCountTooLow) {
            try table.acknowledgeInsertCount(0)
        }
        // Ack one is now valid
        try table.acknowledgeInsertCount(1)
        // Ack more than 1 is invalid
        #expect(throws: DynamicHeaderTableError.ackCountTooHigh) {
            try table.acknowledgeInsertCount(2)
        }
    }

    @Test
    func nearingEviction() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 330,
            initialCapacity: 330,
            targetEvictableFraction: 0.5,
            assumeAllEntriesReceived: true
        )
        for i in 1...7 {
            try table.addHeader(named: "\(i)", value: "")
        }
        // We added 7 entries, each has a length of 33
        // The total capacity is 330 which could store 10 such entries
        // Target evictable is 0.5 which means only the newest 5 are not 'nearing eviction'
        for i in 1...7 {
            let lookup = table.findExistingHeader(named: "\(i)", value: nil)
            #expect(lookup?.isNearingEviction == (i <= 2))
            #expect(lookup?.containsValue == false)
            #expect(lookup?.relativeIndex == 7 - i)
            #expect(lookup?.absoluteIndex == i - 1)
        }
        table.targetEvictableFraction = 0
        // Now, nothing is nearing eviction
        for i in 1...7 {
            let lookup = table.findExistingHeader(named: "\(i)", value: nil)
            #expect(lookup?.isNearingEviction == false)
        }
    }

    @Test
    func unevictableDueToReference() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 165,
            initialCapacity: 165,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
        for i in 1...5 {
            // Each entry has length 33, table is length 165 so can fit exactly 5 such entries
            let addedIndex = try table.addHeader(named: "\(i)", value: "")
            table.addReference(addedIndex)
        }
        // No space for 6th and nothing is evictable due to references
        #expect(throws: HeaderTableError.cannotPurge) {
            try table.addHeader(named: "6", value: "")
        }
        // Dereferencing an entry other than the oldest doesn't help, because it's a fifo queue
        table.removeReference(3)
        // Still no space
        #expect(throws: HeaderTableError.cannotPurge) {
            try table.addHeader(named: "6", value: "")
        }
        // Dereferencing the oldest entry (absolute index 0) makes space
        table.removeReference(0)
        let addedIndex = try table.addHeader(named: "6", value: "")
        #expect(addedIndex == 5)
        // Now we're full again
        #expect(throws: HeaderTableError.cannotPurge) {
            try table.addHeader(named: "7", value: "")
        }
    }

    /// We must not evict entries which haven't been received, even if there are no references.
    @Test
    func unevictableDueToReceiveCount() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 165,
            initialCapacity: 165,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: false
        )
        for i in 1...5 {
            // Each entry has length 33, table is length 165 so can fit exactly 5 such entries
            try table.addHeader(named: "\(i)", value: "")
        }
        // There are no references to anything. But still we can't evict because the knownReceivedCount is too low
        #expect(throws: HeaderTableError.cannotPurge) {
            try table.addHeader(named: "6", value: "")
        }
        // increase the known received count
        try table.acknowledgeInsertCount(1)
        try table.addHeader(named: "6", value: "")
        // Now we're full again
        #expect(throws: HeaderTableError.cannotPurge) {
            try table.addHeader(named: "7", value: "")
        }
    }

    @Test
    func setCurrentCapacity() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 100,
            initialCapacity: 0,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: false
        )
        // Can't set current higher than max
        #expect(throws: DynamicHeaderTableError.capacityTooHigh) {
            try table.setCurrentCapacity(200)
        }
        // Can set current to lower than max
        try table.setCurrentCapacity(50)
        // Can set current equal to max
        try table.setCurrentCapacity(100)
    }

    @Test
    func cantReduceCapacityDueToReferences() throws {
        var table = DynamicHeaderTable(
            maximumCapacity: 40,
            initialCapacity: 40,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )

        // Add an entry, it has length 33
        let addedIndex = try table.addHeader(named: "a", value: "")
        table.addReference(addedIndex)

        // Reducing capacity to less than 33 is now an error because of the reference making the entry un-purgeable
        #expect(throws: HeaderTableError.cannotPurge) {
            try table.setCurrentCapacity(30)
        }

        // Reducing maximum is also not ok because that also reduces the current capacity
        #expect(throws: HeaderTableError.cannotPurge) {
            try table.setCurrentCapacity(30)
        }

        table.removeReference(addedIndex)

        // Reducing capacity is ok now
        try table.setCurrentCapacity(0)
    }
}

extension DynamicHeaderTable {
    fileprivate func findExistingHeader(
        named name: String,
        value: String?
    ) -> DynamicTableLookupResult? {
        guard let name = HTTPField.Name(name) else { return nil }
        return self.findExistingHeader(named: name, value: value)
    }

    @discardableResult
    fileprivate mutating func addHeader(named name: String, value: String) throws -> Int {
        try self.addHeader(named: HTTPField.Name(name)!, value: value)
    }
}
