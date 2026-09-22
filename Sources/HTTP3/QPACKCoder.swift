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

public import HTTPTypes
@_spi(PackageInternal) import QPACK

/// QPACK encoding and decoding for a HTTP/3 connection.
///
/// This implementation does not support the QPACK dynamic table. It advertises a
/// `SETTINGS_QPACK_MAX_TABLE_CAPACITY` of zero and encodes against the static table only, which means:
///
/// - Encoding and decoding are pure functions of the fields: there is no per-connection QPACK state, and the
///   coder can be shared freely between all streams of a connection.
/// - Decoding never blocks, so ``decodeHeaders(_:)`` returns its result synchronously.
/// - Neither endpoint's QPACK unidirectional streams are ever written to, so this endpoint does not create
///   them. See RFC 9204 § 4.2, which permits omitting a stream that will not be used. The peer is still
///   allowed to create its own, but anything it sends on them which implies a dynamic table is a connection
///   error, which is enforced where those streams are read rather than here.
@_spi(PackageInternal)
public struct QPACKCoder: Sendable {
    private let encoder: QPACKEncoder
    private let decoder: QPACKDecoder

    @_spi(PackageInternal)
    public init() {
        self.encoder = QPACKEncoder()
        self.decoder = QPACKDecoder()
    }

    // MARK: Encode

    /// QPACK encode your HTTP fields.
    ///
    /// Use this method for headers and trailers.
    ///
    /// - Returns: The encoded field section, ready to be framed as a HEADERS frame.
    @_spi(PackageInternal)
    public func encodeHeaders(_ fields: [HTTPField]) -> HTTP3PartialFrame.Headers {
        HTTP3PartialFrame.Headers(fieldSection: self.encoder.encode(headers: fields))
    }

    // MARK: Decode

    /// The reason a field section could not be decoded.
    ///
    /// A malformed message fails only its own stream, while anything a conformant encoder could not have
    /// produced is fatal to the connection.
    @_spi(PackageInternal)
    public enum DecodeError: Error {
        /// The connection must be torn down with this error.
        case connectionError(HTTP3Error)
        /// Only the stream the field section arrived on is affected.
        case streamError(HTTP3Error)

        /// The underlying error, whichever kind it is.
        @_spi(PackageInternal)
        public var error: HTTP3Error {
            switch self {
            case .connectionError(let error), .streamError(let error):
                return error
            }
        }
    }

    /// Decode incoming HTTP fields. Use this method for headers and trailers.
    @_spi(PackageInternal)
    public func decodeHeaders(_ headers: HTTP3PartialFrame.Headers) throws(DecodeError) -> [HTTPField] {
        do {
            return try self.decoder.decodeFieldSection(headers.fieldSection)
        } catch {
            switch error {
            case .invalidFieldSection, .invalidReference:
                // RFC 9204 § 2.2.3: if the decoder encounters a reference to a dynamic table entry which has
                // been evicted, or whose absolute index is at or above the Required Insert Count, it MUST
                // treat this as a connection error of type QPACK_DECOMPRESSION_FAILED. With no dynamic table
                // any such reference falls into that category, as does a non-zero Required Insert Count.
                throw DecodeError.connectionError(
                    HTTP3Error(
                        code: .qpackDecoderError,
                        message: "Could not decode QPACK headers",
                        cause: error,
                        errorCode: .qpackDecompressionFailed,
                        location: .here()
                    )
                )
            case .invalidHeaderName:
                // Here we did decode fine, but the header is not valid in HTTP/3 (e.g. it isn't lower case).
                // This is a malformed message, a stream level error. Not a connection error.
                throw DecodeError.streamError(
                    HTTP3Error(
                        code: .qpackDecoderError,
                        message: "Could not decode QPACK headers",
                        cause: error,
                        errorCode: .messageError,
                        location: .here()
                    )
                )
            }
        }
    }
}
