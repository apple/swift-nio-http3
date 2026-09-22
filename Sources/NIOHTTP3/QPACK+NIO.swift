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

@_spi(PackageInternal) import HTTP3
public import NIOCore
@_spi(PackageInternal) public import QPACK

extension QPACKDecoderInstructionDecoder: NIOSingleStepByteToMessageDecoder {}
@available(anyAppleOS 26.0, *)
extension QPACKEncoderInstructionDecoder: NIOSingleStepByteToMessageDecoder {}

/// Receives the connection-level errors raised on the peer's QPACK unidirectional streams.
///
/// Those streams carry nothing this endpoint acts on — see ``QPACKInboundEncoderStreamHandler`` and
/// ``QPACKInboundDecoderStreamHandler`` — so reporting errors is all their handlers ever need to do.
protocol QPACKInboundStreamDelegate: ~Copyable {
    func onError(_ error: HTTP3Error)
}

/// The peer sent a QPACK instruction which implies a dynamic table, which this implementation does not use.
struct UnsupportedQPACKInstruction: Error, Hashable {}
