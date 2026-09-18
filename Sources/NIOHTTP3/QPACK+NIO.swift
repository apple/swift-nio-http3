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
    ConnectionDelegate: HTTP3.QPACKConnectionDelegate,
    StreamDelegate: HTTP3StreamDelegate
> = HTTP3.QPACKCoder<
    QPACKOutboundEncoderStream,
    QPACKOutboundDecoderStream,
    ConnectionDelegate,
    HTTP3StreamHandler<StreamDelegate, ConnectionDelegate>
>
