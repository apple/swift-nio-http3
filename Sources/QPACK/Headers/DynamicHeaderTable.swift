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

enum DynamicHeaderTableError: Error, Sendable, Hashable {
    /// The insert count has been incremented by a value which is too low to be valid.
    case incrementTooLow
    /// The insert count has been incremented by a value which is too high to be valid.
    case incrementTooHigh
    /// The acknowledged insert count has set to value which is too low to be valid.
    case ackCountTooLow
    /// The acknowledged insert count has set to value which is too high to be valid.
    case ackCountTooHigh
    /// The dynamic table current capacity was set to a value higher than the maximum capacity.
    /// In practice, in HTTP3, this means we received a `Set Dynamic Table Capacity` instruction containing a value higher than the size we advertised in the settings frame.
    case capacityTooHigh
}

struct DynamicTableLookupResult: Sendable, Hashable {
    /// Relative index of the entry in the table.
    var relativeIndex: Int
    /// Absolute index of the entry in the table.
    var absoluteIndex: Int
    /// Does the entry match the value too. If false, only the name was matched.
    var containsValue: Bool
    /// True if this item is old and should be duplicated rather than referencing this existing index.
    var isNearingEviction: Bool
    /// True if the entry is known to be received by the peer.
    var isKnownReceived: Bool
}

/// Implements the dynamic part of the QPACK header table, as defined in
/// [RFC 9204 § 3.2](https://httpwg.org/specs/rfc9204.html#header-table-dynamic).
@usableFromInline
struct DynamicHeaderTable: Sendable {
    /// The actual table, with items looked up by index.
    private var storage: HeaderTableStorage

    /// The maximum permitted size of the dynamic header table as set
    /// through a `SETTINGS_QPACK_MAX_TABLE_CAPACITY` value in a SETTINGS frame.
    private(set) var maximumCapacity: Int

    /// This is the value signalled from the peer in the last "set dynamic table capacity" instruction. See RFC 9204 § 4.3.1.
    /// Although this value is chosen by the peer, they cannot choose a value higher than `self.maximumCapacity`.
    var currentCapacity: Int {
        self.storage.maxSize
    }

    /// The number of items in the table.
    var count: Int {
        self.storage.count
    }

    /// The total number of entries ever inserted.
    var insertCount: Int {
        // The item with the highest absolute index has a relative index of 0
        guard let item = self.get(relativeIndex: 0) else {
            return 0
        }
        // The total insert count is one more than the highest absolute index, because it's 0-based
        return item.absoluteIndex + 1
    }

    /// 2.1.4. Known Received Count: total number of insertions and duplications acknowledged by the decoder.
    private(set) var knownReceivedCount: Int = 0

    /// The fraction of the table we want to keep evictable.
    /// E.g. if you set to 0.1, we won't reference anything in the last (oldest) tenth of the table.
    /// This means we avoid references to entries nearing eviction, which can reduce blocking.
    /// This is not a guarantee, if requests come too fast we won't be able to maintain this fraction.
    var targetEvictableFraction: Double {
        didSet {
            assert(self.targetEvictableFraction >= 0 && self.targetEvictableFraction < 1)
        }
    }

    /// Should be true for decoder, false for encoder.
    var assumeAllEntriesReceived: Bool

    /// Entries with absolute index higher than this must not be evicted.
    /// Entries with absolute index equal to or lower than this have been received, and can be evicted as long
    /// as there are no references.
    /// `nil` means there is no max - everything is evictable.
    private var maximumEvictableAbsoluteIndex: Int? {
        // 2.1.1
        // A dynamic table entry cannot be evicted immediately after insertion, even if it has never been referenced.
        // Once the insertion of a dynamic table entry has been acknowledged and there are no outstanding references
        // to the entry in unacknowledged representations, the entry becomes evictable
        if self.assumeAllEntriesReceived {
            return nil  // everything is evictable
        } else {
            return self.knownReceivedCount - 1  // index is one less than count
        }
    }

    init(
        maximumCapacity: Int,
        initialCapacity: Int,
        targetEvictableFraction: Double,
        assumeAllEntriesReceived: Bool
    ) {
        assert(maximumCapacity >= initialCapacity)
        self.storage = HeaderTableStorage(maxSize: initialCapacity)
        self.maximumCapacity = maximumCapacity
        assert(targetEvictableFraction >= 0 && targetEvictableFraction < 1)
        self.targetEvictableFraction = targetEvictableFraction
        self.assumeAllEntriesReceived = assumeAllEntriesReceived
    }

    /// Retrieve an entry with a given relative index (zero-based).
    func get(relativeIndex: Int) -> HeaderTableEntry? {
        if relativeIndex >= self.count || relativeIndex < 0 {
            return nil
        }
        return self.storage[relativeIndex]
    }

    /// Retrieve an entry with a given absolute index (zero-based).
    /// Can return nil if the entry doesn't exist (May have never existed or may have been evicted).
    func get(absoluteIndex: Int) -> HeaderTableEntry? {
        guard let firstEntry = self.get(relativeIndex: 0) else {
            return nil
        }
        let highestAbsoluteIndex = firstEntry.absoluteIndex
        // Absolute index is the reverse order of relative, so self[n].absoluteIndex == highestAbsoluteIndex - n
        let relativeIndex = highestAbsoluteIndex - absoluteIndex
        return self.get(relativeIndex: relativeIndex)
    }

    /// Searches the table for a matching header, optionally with a particular value. If
    /// a match is found, returns the index of the item and an indication whether it contained
    /// the matching value as well.
    ///
    /// Invariants: If `value` is `nil`, result `containsValue` is `false`.
    ///
    /// - Parameters:
    ///   - name: The name of the header for which to search.
    ///   - value: Optional value for the header to find.
    /// - Returns: A tuple containing the matching relative index and, if a value was specified as a
    ///            parameter, an indication whether that value was also found. Returns `nil`
    ///            if no matching header name could be located.
    func findExistingHeader(
        named name: HTTPField.Name,
        value: String?
    ) -> DynamicTableLookupResult? {
        // looking for both name and value, but can settle for just name if no value
        // has been provided. Return the first matching name (lowest index) in that case.
        let relativeIndex: Int
        let lengthOffset: Int
        let containsValue: Bool
        if let value {
            // If we have a value, locate the index of the lowest header which contains that
            // value, but if no value matches, return the index of the lowest header with a
            // matching name alone.
            switch self.storage.closestMatch(name: name, value: value) {
            case .full(let closesMatchRelativeIndex, let closesMatchLengthOffset):
                relativeIndex = closesMatchRelativeIndex
                lengthOffset = closesMatchLengthOffset
                containsValue = true
            case .partial(let closesMatchRelativeIndex, let closesMatchLengthOffset):
                relativeIndex = closesMatchRelativeIndex
                lengthOffset = closesMatchLengthOffset
                containsValue = false
            case .none:
                return nil
            }
        } else {
            // no `first` on AnySequence, just `first(where:)`
            guard let index = self.storage.firstRelativeIndex(matching: name) else { return nil }
            relativeIndex = index.relativeIndex
            containsValue = false
            lengthOffset = index.lengthOffset
        }
        // Force unwrap is safe because we know an entry exists at this index, we just searched for it above
        let absolute = self.get(relativeIndex: relativeIndex)!.absoluteIndex
        let maxOffset = Int(Double(self.currentCapacity) * (1.0 - self.targetEvictableFraction))
        let isNearingEviction = lengthOffset > maxOffset
        return .init(
            relativeIndex: relativeIndex,
            absoluteIndex: absolute,
            containsValue: containsValue,
            isNearingEviction: isNearingEviction,
            isKnownReceived: absolute < self.knownReceivedCount
        )
    }

    /// Appends a header to the table. Note that if this succeeds, the new item's index
    /// is always zero.
    ///
    /// - Parameters:
    ///   - name: The name of the header field.
    ///   - value: A String representing the value of the header field.
    /// - Throws: If the header cannot fit in the storage.
    /// - Returns: The absolute index of the added header.
    @discardableResult
    mutating func addHeader(named name: HTTPField.Name, value: String) throws(HeaderTableError) -> Int {
        try self.storage.add(
            name: name,
            value: value,
            maximumEvictableAbsoluteIndex: self.maximumEvictableAbsoluteIndex
        )
        .absoluteIndex
    }

    /// Increment `knownReceivedCount` (§ 2.1.4).
    mutating func insertCountIncrement(by: Int) throws(DynamicHeaderTableError) {
        // RFC 9204 § 4.4.3 An encoder that receives an Increment field equal to zero, or one that increases the
        // Known Received Count beyond what the encoder has sent, MUST treat this as a connection error
        guard by > 0 else { throw DynamicHeaderTableError.incrementTooLow }
        let (newKnownReceivedCount, overflow) = self.knownReceivedCount.addingReportingOverflow(by)
        guard !overflow, newKnownReceivedCount <= self.insertCount else {
            throw DynamicHeaderTableError.incrementTooHigh
        }
        self.knownReceivedCount = newKnownReceivedCount
    }

    /// When a section is acknowledged or a stream is closed, all the fields used in that stream are implicitly ack'd.
    /// See RFC 9204 § 2.1.4 for details.
    mutating func acknowledgeInsertCount(_ count: Int) throws(DynamicHeaderTableError) {
        guard count > 0 else {
            throw DynamicHeaderTableError.ackCountTooLow
        }
        guard count <= self.insertCount else {
            throw DynamicHeaderTableError.ackCountTooHigh
        }
        self.knownReceivedCount = max(self.knownReceivedCount, count)
    }

    /// Set the size to which the dynamic table may currently grow. Represents
    /// the current maximum length signaled by the peer (RFC 9204 § 4.3.1).
    ///
    /// - Note: This value cannot exceed `self.maximumCapacity`.
    mutating func setCurrentCapacity(_ capacity: Int) throws {
        guard capacity <= self.maximumCapacity else {
            // This means the remote sent us a "set dynamic table capacity" instruction with a value higher than the value we sent in the SETTINGS frame.
            throw DynamicHeaderTableError.capacityTooHigh
        }
        try self.storage.setTableSize(to: capacity, maximumEvictableAbsoluteIndex: self.maximumEvictableAbsoluteIndex)
    }

    mutating func addReference(_ absoluteIndex: Int) {
        self.storage.addReference(absoluteIndex: absoluteIndex)
    }

    mutating func removeReference(_ absoluteIndex: Int) {
        self.storage.removeReference(absoluteIndex: absoluteIndex)
    }
}
