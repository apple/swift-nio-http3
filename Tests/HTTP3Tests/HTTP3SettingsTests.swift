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

import HTTP3
import NIOCore
import Testing

struct HTTP3SettingsTests {
    @Test
    func makeSettings() throws {
        let settings = HTTP3Settings(
            qpackMaximumTableCapacity: 100,
            qpackBlockedStreams: 200,
            maximumFieldSectionSize: 300
        )
        #expect(settings.qpackMaximumTableCapacity == 100)
        #expect(settings.qpackBlockedStreams == 200)
        #expect(settings.maximumFieldSectionSize == 300)
        #expect(settings.other == [])
    }

    @Test
    func unparsedSettings() throws {
        let settings = try HTTP3Settings(parsing: [
            HTTP3Setting(identifier: .init(extensionSetting: 100)!, value: 30),
            HTTP3Setting(identifier: .init(extensionSetting: 200)!, value: 30),
            HTTP3Setting(identifier: .init(extensionSetting: 300)!, value: 30),
            HTTP3Setting(identifier: .qpackBlockedStreams, value: 40),
            HTTP3Setting(identifier: .qpackMaximumTableCapacity, value: 50),
        ])
        #expect(settings.qpackBlockedStreams == 40)
        #expect(settings.qpackMaximumTableCapacity == 50)
        #expect(settings.maximumFieldSectionSize == nil)
        #expect(
            settings.other
                == [
                    HTTP3Setting(identifier: .init(extensionSetting: 100)!, value: 30),
                    HTTP3Setting(identifier: .init(extensionSetting: 200)!, value: 30),
                    HTTP3Setting(identifier: .init(extensionSetting: 300)!, value: 30),
                ]
        )
    }

    @Test(arguments: [0, 2, 3, 4, 5])
    func forbiddenSettingsIdentifier(identifier: UInt64) {
        #expect(HTTP3Setting.Identifier(extensionSetting: identifier) == nil)
    }

    @Test
    func duplicateKnownSetting() {
        expectH3Error(code: .invalidFramePayload, h3ErrorCode: .settingsError) {
            _ = try HTTP3Settings(parsing: [
                .init(identifier: .qpackBlockedStreams, value: 30),
                .init(identifier: .qpackBlockedStreams, value: 40),
            ])
        }
    }

    @Test
    func duplicateUnknownSetting() {
        expectH3Error(code: .invalidFramePayload, h3ErrorCode: .settingsError) {
            _ = try HTTP3Settings(parsing: [
                .init(identifier: .init(extensionSetting: 100)!, value: 30),
                .init(identifier: .init(extensionSetting: 100)!, value: 40),
            ])
        }
    }

    @Test
    func settingsCoding() throws {
        var buffer = ByteBuffer()
        let settings = try HTTP3Settings(parsing: [
            HTTP3Setting(identifier: .qpackBlockedStreams, value: 1),
            HTTP3Setting(identifier: .qpackMaximumTableCapacity, value: 2),
            HTTP3Setting(identifier: .maximumFieldSectionSize, value: 3),
            HTTP3Setting(identifier: .init(extensionSetting: 20)!, value: 4),
            HTTP3Setting(identifier: .init(extensionSetting: 30)!, value: 5),
        ])
        let writtenBytes = buffer.writeHTTP3Settings(settings)
        #expect(writtenBytes == 10)
        #expect(
            [UInt8](buffer: buffer)
                == [
                    7, 1,
                    1, 2,
                    6, 3,
                    20, 4,
                    30, 5,
                ]
        )
        // try decoding it back
        let decoded = try? buffer.readHTTP3Settings()
        #expect(buffer.readableBytes == 0)
        #expect(decoded == settings)
    }

    @Test
    func forbiddenSettingsIdentifierWhenDecoding() {
        let badIdentifiers: [UInt8] = [0, 2, 3, 4, 5]
        for identifier in badIdentifiers {
            // The format is the identifier followed by the value (we're using 1 as the value here)
            let encodedSettingsBytes: [UInt8] = [identifier, 1]
            var buffer = ByteBuffer(bytes: encodedSettingsBytes)
            expectH3Error(
                code: .invalidFramePayload,
                h3ErrorCode: .settingsError,
                message: "Setting identifier is forbidden"
            ) {
                _ = try buffer.readHTTP3Settings()
            }
        }
    }

    @Test
    func settingsCodingIgnoresDefault() {
        let settings = HTTP3Settings(qpackBlockedStreams: 0)
        var buffer = ByteBuffer()
        let writtenBytes = buffer.writeHTTP3Settings(settings)
        // The value is the default, so we don't need to write it out
        #expect(writtenBytes == 0)
        #expect(buffer.readableBytes == 0)
    }

    @Test
    func defaultSettings() throws {
        let empty = try HTTP3Settings(parsing: [])
        #expect(empty.qpackMaximumTableCapacity == 0)
        #expect(empty.qpackBlockedStreams == 0)
        #expect(empty.maximumFieldSectionSize == nil)
        #expect(empty.other == [])
    }
}
