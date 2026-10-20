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

/// Why the ``QPACKCoder`` failed.
///
/// The owner of the coder translates this into the error type of the protocol it runs QPACK for. Whether a failure
/// takes down the connection or only the stream it happened on is given by ``isConnectionError``.
@available(anyAppleOS 27, *)
@_spi(PackageInternal)
@nonexhaustive
public enum QPACKError: Error, Sendable, Hashable {
    /// The peer sent its settings more than once.
    case duplicateSettings

    /// The peer's encoder sent an instruction which can't be processed (RFC 9204 § 6).
    case invalidEncoderInstruction

    /// The peer's decoder sent an instruction while no dynamic table is in use.
    case decoderInstructionWithoutDynamicTable

    /// The peer's decoder sent an instruction which can't be processed (RFC 9204 § 6).
    case invalidDecoderInstruction

    /// The prefix of a field section could not have been produced by a conformant encoder (RFC 9204 § 4.5.1.1).
    case invalidFieldSectionPrefix

    /// A field section could not be decoded.
    case decodeError(QPACKDecoderError)

    /// More streams are blocked waiting for dynamic table entries than were promised.
    case tooManyBlockedStreams

    /// Whether the failure is fatal to the connection, rather than only to the stream it happened on.
    ///
    /// Everything which may leave the two dynamic tables out of sync is a connection error. The only stream error
    /// is a field section which decoded fine, but whose field names are not valid in HTTP/3, such as upper case
    /// ones: the message is malformed, but the connection is not at fault.
    public var isConnectionError: Bool {
        switch self {
        case .decodeError(.invalidHeaderName):
            return false
        case .duplicateSettings,
            .invalidEncoderInstruction,
            .decoderInstructionWithoutDynamicTable,
            .invalidDecoderInstruction,
            .invalidFieldSectionPrefix,
            .decodeError(.invalidReference),
            .decodeError(.invalidFieldSection),
            .tooManyBlockedStreams:
            // RFC 9204 § 2.2.3: a reference to a dynamic table entry that has already been evicted or that has an
            // absolute index greater than or equal to the declared Required Insert Count MUST be treated as a
            // connection error of type QPACK_DECOMPRESSION_FAILED.
            return true
        }
    }
}
