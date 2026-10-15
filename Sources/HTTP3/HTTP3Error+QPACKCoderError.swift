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

public import NIOQUICHelpers
@_spi(PackageInternal) public import QPACK

extension HTTP3Error {
    /// The HTTP/3 error for a failure of the ``QPACKCoder``, with the error code RFC 9114 and RFC 9204 prescribe.
    ///
    /// - Parameters:
    ///   - error: The failure of the coder.
    ///   - streamID: The stream the failure happened on, if it is known.
    ///   - location: Where in the HTTP/3 stack the failure was reported. The coder can't record this, so pass
    ///     `.here()` at the call site.
    @_spi(PackageInternal)
    public init(_ error: QPACKError, streamID: QUICStreamID? = nil, location: SourceLocation) {
        switch error {
        case .duplicateSettings:
            // RFC 9114 § 7.2.4: the peer may only send SETTINGS once, and a second one is a connection error.
            self.init(
                code: .unexpectedFrame,
                message: "Received a second settings frame",
                cause: error,
                errorCode: .frameUnexpected,
                location: location
            )
        case .invalidEncoderInstruction:
            self.init(
                code: .qpackEncoderStreamError,
                message: "Invalid encoder instruction",
                cause: error,
                errorCode: .qpackEncoderStreamError,
                location: location
            )
        case .decoderInstructionWithoutDynamicTable:
            self.init(
                code: .qpackDecoderStreamError,
                message: "Decoder instruction received when dynamic table not being used",
                cause: error,
                errorCode: .qpackDecoderStreamError,
                location: location
            )
        case .invalidDecoderInstruction:
            self.init(
                code: .qpackDecoderStreamError,
                message: "Invalid decoder instruction",
                cause: error,
                errorCode: .qpackDecoderStreamError,
                location: location
            )
        case .invalidFieldSectionPrefix:
            self.init(
                code: .qpackDecoderError,
                message: "Invalid field section prefix",
                cause: error,
                errorCode: .qpackDecompressionFailed,
                location: location
            )
        case .decodeError(.invalidFieldSection), .decodeError(.invalidReference):
            self.init(
                code: .qpackDecoderError,
                message: streamID.map { "Could not decode QPACK headers for stream \($0)" }
                    ?? "Could not decode QPACK headers",
                cause: error,
                errorCode: .qpackDecompressionFailed,
                location: location
            )
        case .tooManyBlockedStreams:
            self.init(
                code: .qpackDecoderError,
                message: "Too many streams blocked on QPACK",
                cause: error,
                errorCode: .qpackDecompressionFailed,
                location: location
            )
        case .decodeError(.invalidHeaderName):
            // The field section decoded fine, but a field name isn't valid in HTTP/3: a malformed message.
            self.init(
                code: .qpackDecoderError,
                message: "Could not decode QPACK headers",
                cause: error,
                errorCode: .messageError,
                location: location
            )
        }
    }
}
