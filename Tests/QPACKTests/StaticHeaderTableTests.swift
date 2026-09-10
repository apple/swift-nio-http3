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

struct StaticHeaderTableTests {
    @Test
    func testIndex() throws {
        // RFC 9204 Appendix A. Static Table
        #expect(StaticHeaderTable.get(at: 0)?.0.rawName == ":authority")
        #expect(StaticHeaderTable.get(at: 0)?.1 == "")

        #expect(StaticHeaderTable.get(at: 0)?.0.rawName == ":authority")
        #expect(StaticHeaderTable.get(at: 0)?.1 == "")

        #expect(StaticHeaderTable.get(at: 98)?.0.rawName == "x-frame-options")
        #expect(StaticHeaderTable.get(at: 98)?.1 == "sameorigin")

        #expect(StaticHeaderTable.get(at: 10000) == nil)
    }

    /// The static table and the name lookup are both generated from one table in the
    /// `GenerateStaticHeaderTable` target. Check that they agree with each other, which is what a
    /// stale regeneration would break.
    @Test
    func testGeneratedTablesAgree() throws {
        // A mapping of header name to the static table indices carrying that name, in ascending
        // order. This is what the lookup's groups have to reproduce.
        var indicesByName: [HTTPField.Name: [Int]] = [:]
        for (index, entry) in staticHeaderTable.enumerated() {
            indicesByName[entry.0, default: []].append(index)
        }

        #expect(staticHeaderTable.count == 99)

        var covered = 0
        for (name, expected) in indicesByName {
            let group = StaticHeaderTable.entryGroup(for: name)
            #expect(!group.isEmpty, "\(name.canonicalName)")
            #expect(Array(group.first) + Array(group.second) == expected, "\(name.canonicalName)")
            // The runs must be ascending and disjoint, so the lowest index comes first.
            #expect(group.second.isEmpty || group.first.upperBound < group.second.lowerBound)

            for index in Array(group.first) + Array(group.second) {
                let entry = try #require(StaticHeaderTable.get(at: index))
                #expect(entry.0 == name, "\(name.canonicalName)")
            }
            covered += group.first.count + group.second.count
        }
        // Every entry belongs to exactly one group, so the groups tile the static table.
        #expect(covered == staticHeaderTable.count)
    }

    /// `find` must agree with a linear scan of the static table for every entry, and must not
    /// match names that aren't in the table.
    @Test
    func testFindMatchesLinearScan() throws {
        func linearScan(name: HTTPField.Name, value: String?) -> (index: Int, containsValue: Bool)? {
            var nameOnlyMatch: Int? = nil
            for index in 0..<99 {
                guard let entry = StaticHeaderTable.get(at: index), entry.0 == name else { continue }
                if let value, entry.1 == value {
                    return (index: index, containsValue: true)
                }
                if nameOnlyMatch == nil {
                    nameOnlyMatch = index
                }
            }
            return nameOnlyMatch.map { (index: $0, containsValue: false) }
        }

        var probes: [(HTTPField.Name, String?)] = []
        for index in 0..<99 {
            let entry = try #require(StaticHeaderTable.get(at: index))
            probes.append((entry.0, entry.1))
            probes.append((entry.0, nil))
            probes.append((entry.0, "definitely-not-a-value"))
        }
        // Names that aren't in the static table, including prefixes and suffixes of ones that are.
        for rawName in [
            "x-custom-header", "accep", "accepts", "content-typ", "content-types", "conteat-type",
            "a", "", ":", ":statuz", "access-control-allow-credential",
            "access-control-allow-credentialss", "access-control-allow-credentialz", "zzz",
        ] {
            guard let name = HTTPField.Name(parsed: rawName) else { continue }
            probes.append((name, nil))
            probes.append((name, "some-value"))
        }

        for (name, value) in probes {
            let label = "\(name.canonicalName) / \(value ?? "nil")"
            let expected = linearScan(name: name, value: value)

            let actual = StaticHeaderTable.find(name: name, value: value)
            #expect(actual?.index == expected?.index, "\(label)")
            #expect(actual?.containsValue == expected?.containsValue, "\(label)")
        }
    }

    /// The lookup keys off the canonical (lowercase) name, so casing in the raw name mustn't matter.
    @Test
    func testFindIsCaseInsensitive() throws {
        let name = try #require(HTTPField.Name("Content-Type"))
        #expect(StaticHeaderTable.find(name: name, value: "text/css")?.index == 51)
        #expect(StaticHeaderTable.find(name: name, value: nil)?.index == 44)
    }
}
