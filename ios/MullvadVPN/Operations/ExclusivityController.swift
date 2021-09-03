//
//  ExclusivityController.swift
//  MullvadVPN
//
//  Created by pronebird on 06/07/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation

class ExclusivityController {
    private let lock = NSLock()
    private var operations: [String: [Operation]] = [:]

    static let shared = ExclusivityController()

    private init() {}

    func addOperation(_ operation: Operation, categories: [String]) {
        lock.withCriticalBlock {
            categories.forEach { category in
                _addOperation(operation, category: category)
            }
        }
    }

    func removeOperation(_ operation: Operation, categories: [String]) {
        lock.withCriticalBlock {
            categories.forEach { category in
                _removeOperation(operation, category: category)
            }
        }
    }

    private func _addOperation(_ operation: Operation, category: String) {
        var operationsWithThisCategory = operations[category] ?? []

        if let last = operationsWithThisCategory.last {
            operation.addDependency(last)
        }

        operationsWithThisCategory.append(operation)

        operations[category] = operationsWithThisCategory
    }

    private func _removeOperation(_ operation: Operation, category: String) {
        guard var operationsWithThisCategory = operations[category],
              let index = operationsWithThisCategory.firstIndex(of: operation) else { return }

        operationsWithThisCategory.remove(at: index)
        operations[category] = operationsWithThisCategory
    }
}
