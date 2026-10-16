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
import NIOQUICHelpers
@_spi(PackageInternal) public import QPACK

extension QPACKDecoderInstructionDecoder: NIOSingleStepByteToMessageDecoder {}
@available(anyAppleOS 26.0, *)
extension QPACKEncoderInstructionDecoder: NIOSingleStepByteToMessageDecoder {}

@available(anyAppleOS 26.0, *)
typealias NIOQPACKCoder<
    ConnectionDelegate: QPACK.QPACKConnectionDelegate,
    StreamDelegate: HTTP3StreamDelegate
> = QPACK.QPACKCoder<
    QPACKOutboundEncoderStream,
    QPACKOutboundDecoderStream,
    ConnectionDelegate,
    HTTP3StreamHandler<StreamDelegate, ConnectionDelegate>
>

/// Gives the instructions read from the peer's QPACK streams to the ``QPACKCoder``, and reports any failure to read
/// or apply them to the connection.
@available(anyAppleOS 26.0, *)
struct QPACKInboundStreamDelegate<
    ConnectionDelegate: QPACK.QPACKConnectionDelegate,
    StreamDelegate: HTTP3StreamDelegate
>: QPACKInboundEncoderStreamDelegate, QPACKInboundDecoderStreamDelegate {
    let qpackCoder: NIOQPACKCoder<ConnectionDelegate, StreamDelegate>
    let connection: StreamDelegate

    func onReceivedInstruction(_ instruction: QPACKEncoderInstruction) throws(QPACKError) {
        try self.qpackCoder.receivedIncomingEncoderInstruction(instruction)
    }

    func onReceivedInstruction(_ instruction: QPACKDecoderInstruction) throws(QPACKError) {
        try self.qpackCoder.receivedIncomingDecoderInstruction(instruction)
    }

    func onError(_ error: HTTP3Error) {
        self.connection.onConnectionError(error)
    }
}
