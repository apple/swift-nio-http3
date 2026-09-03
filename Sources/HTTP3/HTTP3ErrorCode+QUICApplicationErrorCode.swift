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
public import NIOQUICHelpers

extension QUICApplicationErrorCode {
    /// Create a ``QUICApplicationErrorCode`` from an ``HTTP3ErrorCode``.
    ///
    /// HTTP/3 error codes are small constants (max `0x0202`) so this conversion is always valid.
    @_spi(PackageInternal)
    public init(_ errorCode: HTTP3ErrorCode) {
        self = QUICApplicationErrorCode(errorCode.rawValue)!
    }
}
