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

import DequeModule
public import HTTP3
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras

extension HTTP3GoawayID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}

enum WriteOrClose<DataType> {
    case write(DataType)
    case close
}

extension WriteOrClose: Equatable where DataType: Equatable {}
extension WriteOrClose: Hashable where DataType: Hashable {}
extension WriteOrClose: Sendable where DataType: Sendable {}

final class OutboundDataRecorderWithClose<DataType: Sendable>: ChannelOutboundHandler {
    typealias OutboundIn = DataType
    typealias OutboundOut = DataType

    enum Error: Swift.Error {
        case countNotMet
    }

    private var data: [WriteOrClose<DataType>] = []

    private let dataPromise: EventLoopPromise<[WriteOrClose<DataType>]>
    private let targetCount: Int

    init(promise: EventLoopPromise<[WriteOrClose<DataType>]>, targetCount: Int) {
        self.dataPromise = promise
        self.targetCount = targetCount
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.dataPromise.fail(Error.countNotMet)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise writePromise: EventLoopPromise<Void>?) {
        let typed = unwrapOutboundIn(data)
        self.data.append(.write(typed))
        if self.data.count == self.targetCount {
            self.dataPromise.succeed(self.data)
        }
        context.write(data, promise: writePromise)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.data.append(.close)
        if self.data.count == self.targetCount {
            self.dataPromise.succeed(self.data)
        }
        context.close(mode: mode, promise: promise)
    }
}

final class OutboundDataRecorder<DataType: Sendable>: ChannelOutboundHandler {
    typealias OutboundIn = DataType
    typealias OutboundOut = DataType

    enum Error: Swift.Error {
        case countNotMet
    }

    private var data: [DataType] = []

    private let dataPromise: EventLoopPromise<[DataType]>
    private let targetCount: Int

    init(promise: EventLoopPromise<[DataType]>, targetCount: Int) {
        self.dataPromise = promise
        self.targetCount = targetCount
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.dataPromise.fail(Error.countNotMet)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise writePromise: EventLoopPromise<Void>?) {
        let typed = unwrapOutboundIn(data)
        self.data.append(typed)
        if self.data.count == self.targetCount {
            self.dataPromise.succeed(self.data)
        }
        context.write(data, promise: writePromise)
    }
}

final class InboundDataRecorder<DataType: Sendable>: ChannelInboundHandler {
    typealias InboundIn = DataType
    typealias InboundOut = DataType

    enum Error: Swift.Error {
        case countNotMet
    }

    private var data: [DataType] = []

    private let promise: EventLoopPromise<[DataType]>
    private let targetCount: Int

    /// - Warning: Don't call this from outside the EL of this handler.
    func getDataOnEventloop() -> [DataType] {
        self.data
    }

    init(promise: EventLoopPromise<[DataType]>, targetCount: Int) {
        self.promise = promise
        self.targetCount = targetCount
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.promise.fail(Error.countNotMet)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let typed = unwrapInboundIn(data)
        self.data.append(typed)
        if self.data.count == self.targetCount {
            self.promise.succeed(self.data)
        }
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Swift.Error) {
        self.promise.fail(error)
    }
}

final class InboundErrorRecorder: ChannelInboundHandler {
    typealias InboundIn = Never

    enum Error: Swift.Error {
        case neverThrew
    }

    private let errorPromise: EventLoopPromise<any Swift.Error>

    init(errorPromise: EventLoopPromise<any Swift.Error>) {
        self.errorPromise = errorPromise
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.errorPromise.fail(Error.neverThrew)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Swift.Error) {
        self.errorPromise.succeed(error)
    }
}

extension NIOLockedValueBox {
    func popFirst<Element>() -> Element? where Value == Deque<Element> {
        self.withLockedValue {
            $0.popFirst()
        }
    }

    func isEmpty() -> Bool where Value: Collection {
        self.withLockedValue {
            $0.isEmpty
        }
    }
}

extension DebugInboundEventsHandler.Event {
    var isChannelRegistered: Bool {
        switch self {
        case .registered: return true
        default: return false
        }
    }

    var isChannelUnregistered: Bool {
        switch self {
        case .unregistered: return true
        default: return false
        }
    }

    var isChannelInactive: Bool {
        switch self {
        case .inactive: return true
        default: return false
        }
    }

    var isChannelReadComplete: Bool {
        switch self {
        case .readComplete: return true
        default: return false
        }
    }

    var readValue: NIOAny? {
        switch self {
        case .read(let data): return data
        default: return nil
        }
    }
}
