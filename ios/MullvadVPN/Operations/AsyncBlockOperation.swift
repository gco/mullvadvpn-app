//
//  AsyncBlockOperation.swift
//  MullvadVPN
//
//  Created by pronebird on 06/07/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation

/// Asynchronous block operation
class AsyncBlockOperation: AsyncOperation {
    typealias Completion = OperationCompletion

    private var block: ((Completion) -> Void)?

    init(_ block: @escaping (Completion) -> Void) {
        self.block = block
        super.init()
    }

    override func main() {
        block?(Completion(operation: self))
        block = nil
    }
}
