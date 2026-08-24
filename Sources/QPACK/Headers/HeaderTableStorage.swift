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
import HTTPTypes

struct HeaderTableEntry: Sendable, Hashable {
    /// The actual field (name and value).
    private var field: HTTPField
    /// The absolute index, which is fixed for the lifetime of the entry as per RFC 9204 § 3.2.4.
    var absoluteIndex: Int
    /// The name of the field.
    var name: HTTPField.Name {
        self.field.name
    }

    /// The value of the field.
    var value: String {
        self.field.value
    }

    fileprivate init(name: HTTPField.Name, value: String, absoluteIndex: Int) {
        let field = HTTPField(name: name, value: value)
        self.init(field: field, absoluteIndex: absoluteIndex)
    }

    fileprivate init(field: HTTPField, absoluteIndex: Int) {
        self.field = field
        self.absoluteIndex = absoluteIndex
    }

    /// RFC 9204 § 3.2.1:
    ///
    /// The size of an entry is the sum of its name's length in bytes, its value's length in bytes, and 32 additional bytes.
    /// The size of an entry is calculated using the length of its name and value without Huffman encoding applied.
    var length: Int {
        self.name.rawName.utf8.count + self.value.utf8.count + 32
    }
}

enum HeaderTableError: Error, Hashable, Sendable {
    case insufficientStorage
    case cannotPurge
}

/// Storage for the header tables, both static and dynamic. Similar in spirit to
/// `HPACKHeaders` and `NIOHTTP1.HTTPHeaders`, but uses a ring buffer to hold the bytes to
/// avoid allocation churn while evicting and replacing entries.
@usableFromInline
struct HeaderTableStorage: Sendable {
    private var headers: Deque<HeaderTableEntry>
    private var lastIndex: Int?

    /// The maximum length of all items in the table. Trying to insert an entry which would result in the current length going past this would result in a purge.
    /// This is the value signalled from the peer in the last "set dynamic table capacity" instruction. See RFC 9204 § 4.3.1.
    internal private(set) var maxSize: Int

    /// The sum of the lengths of all the items currently in the deque, as defined in RFC 9204 § 3.2.1.
    internal private(set) var length: Int = 0

    /// Reference counter for each absolute index.
    private var references = [Int: Int]()  // absolute index : ref count

    var count: Int {
        self.headers.count
    }

    init(maxSize: Int) {
        self.maxSize = maxSize
        self.headers = .init(minimumCapacity: self.maxSize / QPACKConstants.estimatedBytesPerHeader)
    }

    subscript(index: Int) -> HeaderTableEntry {
        let baseIndex = self.headers.index(self.headers.startIndex, offsetBy: index)
        return self.headers[baseIndex]
    }

    enum MatchType {
        // Length offset is the length of headers before this entry + the length of this entry
        case full(relativeIndex: Int, lengthOffset: Int)
        case partial(relativeIndex: Int, lengthOffset: Int)
        case none
    }

    func closestMatch(name: HTTPField.Name, value: String) -> MatchType {
        var partialIndex: Int?
        var lengthBeforePartial = 0

        // Yes, I'm manually reimplementing IndexingIterator here. This is because
        // the excess ARC in this loop shows up in our profiles pretty substantially,
        // and it's triggered by https://bugs.swift.org/browse/SR-13931.
        //
        // Working around this until the above is resolved.
        var offset = 0
        var index = self.headers.startIndex

        var lengthBeforeHeader = 0

        while index < self.headers.endIndex {
            defer {
                // Unchecked arithmetic is safe here, we can't overflow as offset can never exceed count.
                offset &+= 1
                self.headers.formIndex(after: &index)
            }

            if partialIndex == nil {
                lengthBeforePartial += self.headers[index].length
            }
            lengthBeforeHeader += self.headers[index].length

            // Check if the header name matches.
            guard self.headers[index].name == name else {
                continue
            }

            if partialIndex == nil {
                partialIndex = offset
            }

            if value == self.headers[index].value {
                return .full(relativeIndex: offset, lengthOffset: lengthBeforeHeader)
            }
        }

        if let partial = partialIndex {
            return .partial(relativeIndex: partial, lengthOffset: lengthBeforePartial)
        } else {
            return .none
        }
    }

    /// - Parameter name: The header name to find.
    /// - Returns: The smallest matching index, and the length of headers before this entry + the length of this entry.
    func firstRelativeIndex(matching name: HTTPField.Name) -> (relativeIndex: Int, lengthOffset: Int)? {
        var lengthBeforeHeader = 0
        for index in self.headers.indices {
            let header = self.headers[index]
            lengthBeforeHeader += header.length
            if header.name == name {
                return (index, lengthBeforeHeader)
            }
        }
        return nil
    }

    mutating func setTableSize(to newSize: Int, maximumEvictableAbsoluteIndex: Int?) throws(HeaderTableError) {
        guard newSize >= 0 else {
            fatalError("Header table storage size must be ≥ 0")
        }
        // Potentially need to clear out some things first
        while newSize < self.length {
            try self.purgeOne(maximumEvictableAbsoluteIndex: maximumEvictableAbsoluteIndex)
        }

        self.maxSize = newSize
    }

    mutating func add(
        name: HTTPField.Name,
        value: String,
        maximumEvictableAbsoluteIndex: Int?
    ) throws(HeaderTableError) -> HeaderTableEntry {
        // This can't overflow unless we have more than Int.max items.
        // We make sure the sum of the lengths of the entries aren't more than maxSize
        // maxSize is also an Int. Every entry has a length of at least 32. Therefore the entries will reach maxSize long before lastIndex will overflow.
        let nextIndex = self.lastIndex?.advanced(by: 1) ?? 0
        let entry = HeaderTableEntry(name: name, value: value, absoluteIndex: nextIndex)

        if entry.length > self.maxSize {
            // We can't free up enough space. This IS an error in QPACK, unlike in HPACK
            throw HeaderTableError.insufficientStorage
        }

        var newLength = self.length + entry.length
        if newLength > self.maxSize {
            try self.purge(
                toRelease: newLength - self.maxSize,
                maximumEvictableAbsoluteIndex: maximumEvictableAbsoluteIndex
            )
            newLength = self.length + entry.length
        }

        self.headers.prepend(entry)
        self.length = newLength
        self.lastIndex = nextIndex

        return entry
    }

    /// Purges at least `toRelease` bytes from the table, where 'bytes' refers to the byte-count
    /// of a table entry specified in RFC 9204: [name octets] + [value octets] + 32.
    ///
    /// The free space in the table after this function returns will be at least `count` more than before.
    ///
    /// - Parameters
    ///    - count: The table entry length of bytes to remove from the table.
    ///    - maximumEvictableAbsoluteIndex: The smallest absolute index which may be purged.
    /// - Throws: If entries can't be purged because it has references or an index higher than the maximumEvictableAbsoluteIndex.
    mutating func purge(toRelease count: Int, maximumEvictableAbsoluteIndex: Int?) throws(HeaderTableError) {
        var available = self.maxSize - self.length
        let needed = available + count
        while available < needed && !self.headers.isEmpty {
            available += try self.purgeOne(maximumEvictableAbsoluteIndex: maximumEvictableAbsoluteIndex)
        }
    }

    ///  Purge the oldest item.
    ///  Items cannot be purged if they have references, or if they have an absolute index less than `maximumEvictableAbsoluteIndex`.
    /// - Parameter maximumEvictableAbsoluteIndex: The smallest absolute index which may be purged.
    /// - Returns: The length of the entry which was purged.
    /// - Throws: If the oldest item cannot be purged.
    @discardableResult
    private mutating func purgeOne(maximumEvictableAbsoluteIndex: Int?) throws(HeaderTableError) -> Int {
        // Remember: we're removing from the *end* of the header list, since we *prepend* new items there, but we're
        // removing bytes from the *start* of the storage, because we *append* there.
        guard let entry = self.headers.last else {
            fatalError("should not call purgeOne() unless we have something to purge")
        }
        if let ref = references[entry.absoluteIndex], ref != 0 {
            throw HeaderTableError.cannotPurge
        }
        if let maximumEvictableAbsoluteIndex, entry.absoluteIndex > maximumEvictableAbsoluteIndex {
            throw HeaderTableError.cannotPurge
        }
        self.headers.removeLast()
        self.length -= entry.length
        return entry.length
    }

    mutating func addReference(absoluteIndex: Int) {
        let current = self.references[absoluteIndex] ?? 0
        self.references[absoluteIndex] = current + 1
    }

    mutating func removeReference(absoluteIndex: Int) {
        guard let current = self.references[absoluteIndex], current > 0 else {
            assertionFailure("Tried to remove a reference to index \(absoluteIndex) which has no references")
            return
        }
        self.references[absoluteIndex] = current - 1
    }
}

extension HeaderTableStorage: CustomStringConvertible {
    @usableFromInline
    var description: String {
        let array: [(String, String)] = self.headers.map { header in
            (header.name.canonicalName, header.value)
        }
        return array.description
    }
}
