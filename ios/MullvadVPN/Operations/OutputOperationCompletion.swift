//
//  OutputOperationCompletion.swift
//  OutputOperationCompletion
//
//  Created by pronebird on 02/08/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

class OutputOperationCompletion<Output> {
    private var completed = false
    private let lock = NSLock()
    private weak var operation: OperationProtocol?
    private var finishOperation: ((Output) -> Void)?

    init<T>(operation anOperation: T) where T: OutputOperation, T.Output == Output {
        operation = anOperation
        finishOperation = { [weak anOperation] output in
            anOperation?.finish(with: output)
        }
    }

    deinit {
        assert(completed, "OutputOperationCompletion for \(assertionDescriptionForOperation(operation)) has not been completed.")
    }

    func callAsFunction(_ output: Output) {
        lock.withCriticalBlock {
            completed = true
            finishOperation?(output)
        }
    }
}
