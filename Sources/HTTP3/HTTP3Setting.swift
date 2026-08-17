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

/// A type representing a single HTTP/3 setting.
public struct HTTP3Setting: Hashable, Sendable {
    /// The setting's identifier.
    public var identifier: Identifier

    /// The setting's value. This is actually 62 bits.
    public var value: UInt64

    /// Initializes a new ``HTTP3Setting``.
    /// - Precondition: The value must be a QUIC-encodable integer, that means it must be between 1 and 2^62-1. Otherwise, this function will trap.
    ///
    /// - Parameters:
    ///   - identifier: The setting's identifier.
    ///   - value: The setting's value.
    public init(identifier: Identifier, value: UInt64) {
        precondition(value <= QUICEncodableInteger.maxValue, "Invalid settings value \(value)")
        self.identifier = identifier
        self.value = value
    }
}

extension HTTP3Setting {
    /// An identifier for a `HTTP3Setting`.
    ///
    /// See RFC 9114 § 7.2.4.1 for more details.
    public struct Identifier: Hashable, Sendable {
        /// The raw value of the settings parameter. This is actually 62 bits.
        internal var rawValue: UInt64

        /// Initializes a new extension ``HTTP3Setting/Identifier``.
        ///
        /// If this is a known setting, use one of the static values.
        /// If this identifier is forbidden, as specified in RFC 9114 § 7.2.4.1, this initializer will return nil.
        /// - Precondition: The value must be a QUIC-encodable integer, that means it must be between 1 and 2^62-1. Otherwise, this function will trap.
        public init?(extensionSetting: UInt64) {
            // RFC 9114 § 7.2.4.1: Setting identifiers that were defined in [HTTP/2] where there is no corresponding HTTP/3 setting have also been reserved (Section 11.2.2).
            // These reserved settings MUST NOT be sent, and their receipt MUST be treated as a connection error of type H3_SETTINGS_ERROR.
            switch extensionSetting {
            case 0,
                2,  // SETTINGS_ENABLE_PUSH
                3,  // SETTINGS_MAX_CONCURRENT_STREAMS
                4,  // SETTINGS_INITIAL_WINDOW_SIZE
                5:  // SETTINGS_MAX_FRAME_SIZE
                return nil
            default:
                precondition(
                    extensionSetting <= QUICEncodableInteger.maxValue,
                    "Invalid settings identifier \(extensionSetting)"
                )
                self.rawValue = extensionSetting
            }
        }

        /// Corresponds to `SETTINGS_QPACK_MAX_TABLE_CAPACITY`.
        ///
        /// The default value is zero. This is the equivalent of the `SETTINGS_HEADER_TABLE_SIZE` from HTTP/2.
        ///
        /// See [RFC 9204 § 5](https://datatracker.ietf.org/doc/html/rfc9204#name-configuration)
        public static let qpackMaximumTableCapacity = Self(extensionSetting: 0x01)!

        /// Corresponds to `HTTP3_SETTINGS_MAX_FIELD_SECTION_SIZE`.
        ///
        /// The default value is unlimited, there is no limit on the field section size..
        ///
        /// See [RFC 9114 § 7.2.4.1](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.4.1)
        public static let maximumFieldSectionSize = Self(extensionSetting: 0x06)!

        /// Corresponds to `SETTINGS_QPACK_BLOCKED_STREAMS`.
        ///
        /// The default value is zero.
        ///
        /// See [RFC 9204 § 5](https://datatracker.ietf.org/doc/html/rfc9204#name-configuration)
        public static let qpackBlockedStreams = Self(extensionSetting: 0x07)!

        /// Corresponds to `SETTINGS_H3_DATAGRAM`.
        ///
        /// The value must be either zero or one; the default is zero. A value of one indicates
        /// that the sender is willing to receive HTTP datagrams.
        ///
        /// See [RFC 9297 § 2.1.1](https://www.rfc-editor.org/rfc/rfc9297.html#section-2.1.1)
        public static let h3Datagram = Self(extensionSetting: 0x33)!
    }
}
