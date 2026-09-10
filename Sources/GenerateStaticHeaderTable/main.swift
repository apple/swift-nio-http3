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

internal import Foundation

// Generates the QPACK static table and its name lookup. Run from the package root:
//
//     swift run GenerateStaticHeaderTable Sources/QPACK/Headers
//
// `staticTable` in `StaticTable.swift` is the source of truth for the table's contents; edit it
// there and regenerate.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: \(arguments[0]) <output-directory>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)

let model = StaticTableModel(staticTable: staticTable)
let url = outputDirectory.appendingPathComponent("StaticHeaderTable+Generated.swift")
do {
    try Data(generateStaticHeaderTable(model).utf8).write(to: url, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("failed to write \(url.path): \(error)\n".utf8))
    exit(1)
}
print("wrote \(url.path)")
