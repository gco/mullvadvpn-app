//
//  Promise+OperationQueue.swift
//  Promise+OperationQueue
//
//  Created by pronebird on 02/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

extension Promise {

    /// Run promise on OperationQueue creating asynchronous Operation that finishes along with the upstream.
    func run(on operationQueue: OperationQueue) -> Promise<Value> {
        return Promise { resolver in
            let operation = AsyncBlockOperation { finish in
                _ = self.observe { completion in
                    resolver.resolve(completion: completion)
                    finish()
                }
            }

            operationQueue.addOperation(operation)
        }
    }

    /// Run promise on OperationQueue creating asynchronous Operation that is mutually exclusive with the given
    /// categories of operations and finishes along with the upstream.
    func run(on operationQueue: OperationQueue, categories: [String]) -> Promise<Value> {
        return Promise { resolver in
            let exclusivityController = ExclusivityController.shared

            let operation = AsyncBlockOperation { finish in
                _ = self.observe { completion in
                    resolver.resolve(completion: completion)
                    finish()
                }
            }

            operation.completionBlock = {
                exclusivityController.removeOperation(operation, categories: categories)
            }

            exclusivityController.addOperation(operation, categories: categories)
            operationQueue.addOperation(operation)
        }
    }
}
