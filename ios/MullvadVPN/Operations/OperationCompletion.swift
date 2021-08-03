//
//  OperationCompletion.swift
//  OperationCompletion
//
//  Created by pronebird on 02/08/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

class OperationCompletion {
    private var completed = false
    private let lock = NSLock()
    private weak var operation: OperationProtocol?

    init(operation anOperation: OperationProtocol) {
        operation = anOperation
    }

    deinit {
        assert(completed, "OperationCompletion for \(assertionDescriptionForOperation(operation)) has not been completed.")
    }

    func callAsFunction() {
        lock.withCriticalBlock {
            completed = true
            operation?.finish()
        }
    }
}

func assertionDescriptionForOperation(_ operation: Operation?) -> String {
    return withUnsafePointer(to: operation) { ptr in
        return "\(operation?.name ?? "unnamed") [\(ptr)]"
    }
}
