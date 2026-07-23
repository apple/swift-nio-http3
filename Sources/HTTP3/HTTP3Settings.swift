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

import struct NIOCore.ByteBuffer

/// Represents connection-wide settings for a HTTP/3 connection.
/// - Warning: Each setting must only be specified once.
public struct HTTP3Settings: Hashable, Sendable {
    private var _qpackMaximumTableCapacity: UInt64?
    private var _qpackBlockedStreams: UInt64?
    private var _maximumFieldSectionSize: UInt64?
    private var _other: [HTTP3Setting] = []

    /// The maximum capacity of the qpack dynamic table. Corresponds to `SETTINGS_QPACK_MAX_TABLE_CAPACITY`.
    /// Default value of 0 is returned if this setting was not explicitly set.
    public var qpackMaximumTableCapacity: UInt64 {
        self._qpackMaximumTableCapacity ?? 0
    }

    /// The maximum number of streams which may be blocked on QPACK at any one time. Corresponds to `SETTINGS_QPACK_BLOCKED_STREAMS`.
    /// Default value of 0 is returned if this setting was not explicitly set.
    public var qpackBlockedStreams: UInt64 {
        self._qpackBlockedStreams ?? 0
    }

    /// The maximum size of a field section. Corresponds to `SETTINGS_MAX_FIELD_SECTION_SIZE`.
    /// Nil is returned if this setting was not explicitly set. This should be interpreted as there being no field section size limit.
    public var maximumFieldSectionSize: UInt64? {
        self._maximumFieldSectionSize
    }

    /// All settings which are not understood by this implementation.
    /// There are guaranteed to be no duplicated identifiers in this array.
    public var other: [HTTP3Setting] {
        self._other
    }

    /// Make an empty settings instance.
    package init() {}

    /// Create a new HTTP3Settings.
    /// Any parameter which is set to nil or omitted will result in the default value being used as per RFC 9114.
    /// - Parameters:
    ///   - qpackMaximumTableCapacity: The maximum capacity of the qpack dynamic table. Corresponds to `SETTINGS_QPACK_MAX_TABLE_CAPACITY`.
    ///   - qpackBlockedStreams: The maximum number of streams which may be blocked on QPACK at any one time. Corresponds to `SETTINGS_QPACK_BLOCKED_STREAMS`.
    ///   - maximumFieldSectionSize: The maximum size of a field section. Corresponds to `SETTINGS_MAX_FIELD_SECTION_SIZE`.
    /// - Precondition: The values must be QUIC-encodable integers, that means they must be between 1 and 2^62-1.
    public init(
        qpackMaximumTableCapacity: UInt64? = nil,
        qpackBlockedStreams: UInt64? = nil,
        maximumFieldSectionSize: UInt64? = nil
    ) {
        self.init()

        precondition(
            qpackMaximumTableCapacity ?? 0 <= QUICEncodableInteger.maxValue,
            "Invalid qpackMaximumTableCapacity value \(qpackMaximumTableCapacity!)"
        )
        precondition(
            qpackBlockedStreams ?? 0 <= QUICEncodableInteger.maxValue,
            "Invalid qpackBlockedStreams value \(qpackBlockedStreams!)"
        )
        precondition(
            maximumFieldSectionSize ?? 0 <= QUICEncodableInteger.maxValue,
            "Invalid maximumFieldSectionSize value \(maximumFieldSectionSize!)"
        )

        self._qpackMaximumTableCapacity = qpackMaximumTableCapacity
        self._qpackBlockedStreams = qpackBlockedStreams
        self._maximumFieldSectionSize = maximumFieldSectionSize
    }

    /// Parse the provided settings into a ``HTTP3Settings``.
    /// - Throws: A ``HTTP3Error`` if any keys are duplicated or invalid.
    public init(parsing unparsed: [HTTP3Setting]) throws {
        self.init()
        for setting in unparsed {
            try self.add(setting)
        }
    }

    /// Used by parsers (such as the implementation of reading settings from a ByteBuffer or dictionary).
    /// This function throws if adding an invalid setting (e.g. an invalid identifier, or a duplicate).
    /// This is the only way to mutate HTTP3Settings, and it means we guarantee HTTP3Settings is always a valid set.
    fileprivate mutating func add(_ setting: HTTP3Setting) throws(HTTP3Error) {
        // Check for duplicates
        // 7.2.4: The same setting identifier MUST NOT occur more than once in the SETTINGS frame.
        // A receiver MAY treat the presence of duplicate setting identifiers as a connection error of type H3_SETTINGS_ERROR.
        @inline(never)
        func duplicateSettingError(
            identifier: HTTP3Setting.Identifier,
            location: HTTP3Error.SourceLocation
        ) -> HTTP3Error {
            HTTP3Error(
                code: .invalidFramePayload,
                message: "Settings contains duplicated identifier \(identifier)",
                cause: nil,
                errorCode: .settingsError,
                location: location
            )
        }

        switch setting.identifier {
        case .qpackMaximumTableCapacity:
            if self._qpackMaximumTableCapacity != nil {
                throw duplicateSettingError(identifier: setting.identifier, location: .here())
            }
            self._qpackMaximumTableCapacity = setting.value
        case .qpackBlockedStreams:
            if self._qpackBlockedStreams != nil {
                throw duplicateSettingError(identifier: setting.identifier, location: .here())
            }
            self._qpackBlockedStreams = setting.value
        case .maximumFieldSectionSize:
            if self._maximumFieldSectionSize != nil {
                throw duplicateSettingError(identifier: setting.identifier, location: .here())
            }
            self._maximumFieldSectionSize = setting.value
        default:
            // A linear search is likely cheaper than using a Set or other technique to detect duplicates
            // That is because we do not expect many unknown settings
            guard !self._other.contains(where: { $0.identifier == setting.identifier }) else {
                throw duplicateSettingError(identifier: setting.identifier, location: .here())
            }
            self._other.append(setting)
        }
    }

    public func hash(into hasher: inout Hasher) {
        // Custom hashing based on computed vars rather than underlying storage
        // This means the default values are used when a setting is not specified
        // E.g. an instance of HTTP3Settings with `qpackMaximumTableCapacity` set explicitly to 0 is the
        // same as one with it not set
        hasher.combine(self.qpackMaximumTableCapacity)
        hasher.combine(self.qpackBlockedStreams)
        hasher.combine(self.maximumFieldSectionSize)
        hasher.combine(self.other)
    }

    public static func == (lhs: HTTP3Settings, rhs: HTTP3Settings) -> Bool {
        // Custom hashing based on computed vars rather than underlying storage
        // This means the default values are used when a setting is not specified
        // E.g. an instance of HTTP3Settings with `qpackMaximumTableCapacity` set explicitly to 0 is the
        // same as one with it not set
        lhs.qpackMaximumTableCapacity == rhs.qpackMaximumTableCapacity
            && lhs.qpackBlockedStreams == rhs.qpackBlockedStreams
            && lhs.maximumFieldSectionSize == rhs.maximumFieldSectionSize && lhs.other == rhs.other
    }
}

extension ByteBuffer {
    /// Reads the entire ByteBuffer and returns as many settings as it finds.
    ///
    /// - Warning: There must not be any extra readable bytes beyond a valid set of settings.
    /// - Throws: If there are any extra readable bytes beyond a valid set of settings, or any of the integers are unparseable.
    package mutating func readHTTP3Settings() throws(HTTP3Error) -> HTTP3Settings {
        var settings = HTTP3Settings()

        // We are going to decode the next setting until we have read the payload length
        while self.readableBytes > 0 {
            guard let rawIdentifier = self.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
                throw HTTP3Error(
                    code: .invalidFramePayload,
                    message: "Setting identifier is not a valid QUIC variable-length integer",
                    cause: nil,
                    errorCode: .frameError,
                    location: .here()
                )
            }
            guard let value = self.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
                throw HTTP3Error(
                    code: .invalidFramePayload,
                    message: "Setting value is not a valid QUIC variable-length integer",
                    cause: nil,
                    errorCode: .frameError,
                    location: .here()
                )
            }
            guard let identifier = HTTP3Setting.Identifier(extensionSetting: rawIdentifier) else {
                // 7.2.4.1: These reserved settings MUST NOT be sent, and their receipt MUST be treated as a connection error of type H3_SETTINGS_ERROR.
                throw HTTP3Error(
                    code: .invalidFramePayload,
                    message: "Setting identifier is forbidden",
                    cause: nil,
                    errorCode: .settingsError,
                    location: .here()
                )
            }

            try settings.add(.init(identifier: identifier, value: value))
        }
        return settings
    }

    /// Write some ``HTTP3Settings`` and return the number of bytes written.
    ///
    /// - Parameter settings: The settings to write.
    /// - Returns: The number of bytes written.
    package mutating func writeHTTP3Settings(_ settings: HTTP3Settings) -> Int {
        var bytesWritten = 0
        if settings.qpackBlockedStreams != 0 {
            bytesWritten += self.writeHTTP3Setting(
                .init(identifier: .qpackBlockedStreams, value: settings.qpackBlockedStreams)
            )
        }
        if settings.qpackMaximumTableCapacity != 0 {
            bytesWritten += self.writeHTTP3Setting(
                .init(identifier: .qpackMaximumTableCapacity, value: settings.qpackMaximumTableCapacity)
            )
        }
        if let maximumFieldSectionSize = settings.maximumFieldSectionSize {
            bytesWritten += self.writeHTTP3Setting(
                .init(identifier: .maximumFieldSectionSize, value: maximumFieldSectionSize)
            )
        }
        for setting in settings.other {
            bytesWritten += self.writeHTTP3Setting(setting)
        }
        return bytesWritten
    }

    /// Write a single ``HTTP3Setting`` and return the number of bytes written.
    ///
    /// - Parameter setting: The setting to write.
    /// - Returns: The number of bytes written.
    private mutating func writeHTTP3Setting(_ setting: HTTP3Setting) -> Int {
        self.writeEncodedInteger(setting.identifier.rawValue, strategy: .quic)
            + self.writeEncodedInteger(setting.value, strategy: .quic)
    }
}
