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

/// A node of the byte trie over a set of equal-length names.
private enum TrieNode {
    /// One candidate is left; confirm it with a whole-string comparison.
    case leaf(String)
    /// Dispatch on the byte at `position`.
    case branch(position: Int, children: [(byte: UInt8, node: TrieNode)])
}

/// Builds a trie discriminating `candidates`, which all have the same length.
///
/// `known` holds the byte positions already dispatched on further up the tree.
private func buildTrie(candidates: [String], known: Set<Int>) -> TrieNode {
    if candidates.count == 1 {
        return .leaf(candidates[0])
    }

    // Dispatch on the byte position that splits the candidates most evenly. Preferring more
    // buckets first, then a smaller largest bucket, keeps the tree shallow.
    var best: (position: Int, buckets: [UInt8: [String]])? = nil
    for position in 0..<candidates[0].utf8.count where !known.contains(position) {
        var buckets: [UInt8: [String]] = [:]
        for candidate in candidates {
            buckets[Array(candidate.utf8)[position], default: []].append(candidate)
        }
        guard buckets.count > 1 else { continue }
        let largest = buckets.values.map(\.count).max()!
        if let current = best {
            let currentLargest = current.buckets.values.map(\.count).max()!
            guard (buckets.count, -largest) > (current.buckets.count, -currentLargest) else { continue }
        }
        best = (position: position, buckets: buckets)
    }

    guard let best else {
        fatalError("Duplicate names in the static table: \(candidates)")
    }
    return .branch(
        position: best.position,
        children: best.buckets.sorted { $0.key < $1.key }.map {
            (byte: $0.key, node: buildTrie(candidates: $0.value, known: known.union([best.position])))
        }
    )
}

/// Generates `entryGroup(canonicalName:utf8:)`: a switch on the name length, then on whichever
/// byte positions discriminate the remaining candidates, then one confirming comparison.
func writeEntryGroupLookup(_ model: StaticTableModel, to writer: inout SourceWriter) {
    let namesByLength = model.namesByLength

    func write(_ node: TrieNode, to writer: inout SourceWriter) {
        switch node {
        case .leaf(let name):
            let group = model.groups[name]!
            var arguments = "\(group.first.lowerBound), \(group.first.upperBound)"
            if !group.second.isEmpty {
                arguments += ", \(group.second.lowerBound), \(group.second.upperBound)"
            }
            writer.write("canonicalName == \(name.swiftLiteral) ? StaticEntryGroup(\(arguments)) : .none")
        case .branch(let position, let children):
            writer.writeSwitch("utf8[position: \(position)]") { writer in
                for child in children {
                    writer.writeCase("case \(child.byte.asciiLiteral)") { writer in
                        write(child.node, to: &writer)
                    }
                }
                writer.writeCase("default") { writer in
                    writer.write(".none")
                }
            }
        }
    }

    writer.write(
        lines: [
            "/// Resolves `canonicalName` to the static table indices carrying that name, or an empty",
            "/// group if the static table doesn't carry it.",
            "///",
            "/// A trie over the UTF-8 bytes of the canonical (lowercase) name: it dispatches on the",
            "/// length first, then on whichever byte positions discriminate the remaining candidates,",
            "/// and finally confirms with a single whole-string comparison. Each dispatch is a jump",
            "/// table, so a lookup costs a handful of loads instead of hashing the whole name.",
            "///",
            "/// `utf8` must be `canonicalName`'s UTF-8 bytes; call `entryGroup(for:)` instead.",
        ]
    )
    let signature = """
        static func entryGroup(canonicalName: String, utf8: UnsafeBufferPointer<UInt8>) -> StaticEntryGroup {
        """
    writer.writeBlock(signature) { writer in
        writer.writeSwitch("utf8.count") { writer in
            for length in namesByLength.keys.sorted() {
                writer.writeCase("case \(length)") { writer in
                    write(buildTrie(candidates: namesByLength[length]!, known: []), to: &writer)
                }
            }
            writer.writeCase("default") { writer in
                writer.write(".none")
            }
        }
    }
}
