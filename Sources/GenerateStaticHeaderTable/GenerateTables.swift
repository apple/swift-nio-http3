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

/// Generates `StaticHeaderTable+Generated.swift`: the static table itself and the name lookup
/// that resolves a name to the indices carrying it.
func generateStaticHeaderTable(_ model: StaticTableModel) -> String {
    var writer = SourceWriter()
    writer.writeLicenseHeader()
    writer.write("import HTTPTypes")
    writer.write()

    writer.write(
        lines: [
            "/// All the static header table entries as defined in RFC 9204 § 3.1.",
            "///",
            "/// The absolute index is the position, which is the array index. Note that the QPACK",
            "/// static table is indexed from 0, whereas the HPACK static table is indexed from 1.",
        ]
    )
    writer.writeBlock("let staticHeaderTable: [(HTTPField.Name, String)] = [", terminator: "]") { writer in
        for (index, entry) in staticTable.enumerated() {
            writer.write("(.init(parsed: \(entry.name.swiftLiteral))!, \(entry.value.swiftLiteral)),  // \(index)")
        }
    }
    writer.write()

    writer.writeBlock("extension StaticHeaderTable {") { writer in
        writeEntryGroupLookup(model, to: &writer)
    }

    return writer.contents
}
