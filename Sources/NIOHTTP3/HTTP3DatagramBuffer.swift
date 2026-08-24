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
import NIOQUICHelpers

struct HTTP3DatagramBuffer {
    /// A batch of buffered datagrams for a given stream ID.
    struct DatagramBatch {
        /// The datagrams, in insertion order.
        private(set) var datagrams: Deque<HTTP3Datagram>
        /// The total size of the buffered datagrams in bytes.
        private(set) var totalSize: Int

        /// Whether the batch is empty.
        var isEmpty: Bool {
            self.datagrams.isEmpty
        }

        init() {
            self.totalSize = 0
            self.datagrams = []
        }

        /// Appends a datagram to the batch.
        mutating func append(_ datagram: HTTP3Datagram) {
            self.datagrams.append(datagram)
            self.totalSize += datagram.payload.readableBytes
        }

        /// Pops the first datagram from the batch.
        mutating func popFirst() -> HTTP3Datagram? {
            guard let datagram = self.datagrams.popFirst() else { return nil }

            self.totalSize &-= datagram.payload.readableBytes
            return datagram
        }

        /// Remove all datagrams from the batch.
        mutating func removeAll() {
            self.totalSize = 0
            self.datagrams.removeAll()
        }
    }

    /// A run of contiguous stream IDs.
    ///
    /// Avoids storing `count` items when one would suffice.
    struct StreamIDRun {
        /// The stream ID associated with the run.
        var streamID: QUICStreamID
        /// The number of times the stream ID appears in the run.
        var count: Int
    }

    /// Batches of datagrams keyed by the ID of the stream they are associated with.
    private var storage: [QUICStreamID: DatagramBatch]
    /// The insertion order of datagrams by stream ID. Stream IDs are batched into 'runs' to avoid
    /// storing `N` contiguous entries where one would be sufficient.
    private var runs: Deque<StreamIDRun>

    #if DEBUG
    /// A set of stream IDs for which datagrams have already been discarded.
    private var unbuffered: Set<QUICStreamID> = []

    private mutating func markUnbuffered(_ streamID: QUICStreamID) {
        self.unbuffered.insert(streamID)
    }

    private func checkNotUnbuffered(_ streamID: QUICStreamID) {
        if self.unbuffered.contains(streamID) {
            fatalError(
                "\(streamID) has been discarded: you can't buffer data for a stream after it has been unbuffered"
            )
        }
    }
    #endif

    /// The total number of bytes currently stored in the buffer.
    private(set) var totalSize: Int

    /// The maximum number of bytes allowed to be stored in the buffer at any one time.
    private let maxAllowedSize: Int

    /// Creates a new buffer, storing at most `maxAllowedSize` bytes at a given time. When the
    /// limit is exceeded, buffered datagrams are evicted by insertion order until the total size
    /// is within limit.
    init(maxAllowedSize: Int) {
        self.runs = []
        self.storage = [:]
        self.totalSize = 0
        self.maxAllowedSize = maxAllowedSize
    }

    /// Append a datagram to the buffer.
    ///
    /// Datagrams may be evicted in order to make space for the new datagram.
    ///
    /// - Important: You must not append a datagram for a stream which has already had its
    ///   frames unbuffered.
    mutating func append(_ datagram: HTTP3Datagram) {
        #if DEBUG
        self.checkNotUnbuffered(datagram.streamID)
        #endif

        if self.runs.isEmpty || self.runs.last!.streamID != datagram.streamID {
            // New bucket.
            self.runs.append(StreamIDRun(streamID: datagram.streamID, count: 1))
        } else {
            // Update an existing bucket.
            let index = self.runs.index(before: self.runs.endIndex)
            self.runs[index].count += 1
        }

        self.storage[datagram.streamID, default: DatagramBatch()].append(datagram)
        self.totalSize += datagram.payload.readableBytes

        self.dropLeadingRunsIfNecessary()
        self.dropDatagramsIfNecessary()
    }

    /// Removes all datagrams for the given stream ID and return them, if they exist.
    mutating func unbufferDatagrams(forStream id: QUICStreamID) -> Deque<HTTP3Datagram>? {
        #if DEBUG
        self.markUnbuffered(id)
        #endif

        guard let batch = self.storage.removeValue(forKey: id) else { return nil }

        self.totalSize -= batch.totalSize
        return batch.datagrams
    }

    /// Removes all datagrams for the given stream ID, if they exist.
    mutating func discardDatagrams(forStream id: QUICStreamID) {
        #if DEBUG
        self.markUnbuffered(id)
        #endif

        if let batch = self.storage.removeValue(forKey: id) {
            self.totalSize -= batch.totalSize
        }
    }

    /// Removes all datagrams for streams with an ID greater than or equal to the given ID.
    mutating func discardDatagrams(forStreamsAtOrAbove id: QUICStreamID) {
        for streamID in self.storage.keys where streamID >= id {
            self.discardDatagrams(forStream: streamID)
        }
    }

    /// Removes all buffered datagrams.
    mutating func discardAllDatagrams() {
        #if DEBUG
        for id in self.storage.keys {
            self.markUnbuffered(id)
        }
        #endif

        self.storage.removeAll()
        self.runs.removeAll()
        self.totalSize = 0
    }

    private mutating func dropLeadingRunsIfNecessary() {
        // Drop leading runs: this is done regardless of whether the max allowed size limit has
        // been exceeded.
        while let run = self.runs.first, !self.storage.keys.contains(run.streamID) {
            self.runs.removeFirst()
        }
    }

    private mutating func dropDatagramsIfNecessary() {
        // Drop datagrams until the total size isn't exceeded.
        while self.totalSize > self.maxAllowedSize && !self.runs.isEmpty {
            let run = self.runs[self.runs.startIndex]

            let dropped = self.storage.dropDatagrams(
                forStreamID: run.streamID,
                bytesToDrop: self.totalSize &- self.maxAllowedSize,
                maxDatagramsToDrop: run.count
            )

            if let dropped {
                self.totalSize &-= dropped.bytes
                self.runs[self.runs.startIndex].count &-= dropped.datagrams

                // The whole run was consumed: drop it.
                if self.runs[self.runs.startIndex].count == 0 {
                    self.runs.removeFirst()
                } else {
                    // The run is non-empty implying enough bytes were consumed. Leave it in place
                    // and exit the loop.
                    break
                }
            } else {
                // Missing stream ID: datagrams for the given stream ID have been unbuffered.
                self.runs.removeFirst()
            }
        }

        assert(self.totalSize <= self.maxAllowedSize)
    }
}

extension [QUICStreamID: HTTP3DatagramBuffer.DatagramBatch] {
    struct Dropped {
        var bytes: Int
        var datagrams: Int

        mutating func record(bytes: Int) {
            self.bytes += bytes
            self.datagrams += 1
        }
    }

    fileprivate mutating func dropDatagrams(
        forStreamID id: QUICStreamID,
        bytesToDrop: Int,
        maxDatagramsToDrop: Int
    ) -> Dropped? {
        self.withBatch(forStreamID: id) { batch -> Dropped? in
            // No batch is fine: it means the datagrams have already been unbuffered.
            if batch == nil { return nil }

            var dropped = Dropped(bytes: 0, datagrams: 0)

            // Fast-path: drop a whole batch.
            if maxDatagramsToDrop >= batch!.datagrams.count, bytesToDrop >= batch!.totalSize {
                dropped.datagrams = batch!.datagrams.count
                dropped.record(bytes: batch!.totalSize)
                batch = nil
            } else {
                while dropped.datagrams < maxDatagramsToDrop, dropped.bytes < bytesToDrop,
                    let removed = batch!.popFirst()
                {
                    dropped.record(bytes: removed.payload.readableBytes)
                }

                // Empty: remove the batch from the dictionary.
                if batch!.isEmpty {
                    batch = nil
                }
            }

            return dropped
        }
    }

    private mutating func withBatch(
        forStreamID id: QUICStreamID,
        mutate: (inout HTTP3DatagramBuffer.DatagramBatch?) -> Dropped?
    ) -> Dropped? {
        mutate(&self[id])
    }
}
