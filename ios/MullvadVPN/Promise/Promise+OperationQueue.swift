//
//  Promise+OperationQueue.swift
//  Promise+OperationQueue
//
//  Created by pronebird on 02/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

extension Promise {

    /// Returns a promise that adds operation that finishes along with the upstream.
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

    /// Returns a promise that adds a mutually exclusive operation that finishes along with the upstream.
    func run(on operationQueue: OperationQueue, categories: [String]) -> Promise<Value> {
        return Promise { resolver in
            let operation = AsyncBlockOperation { finish in
                _ = self.observe { completion in
                    resolver.resolve(completion: completion)
                    finish()
                }
            }

            ExclusivityController.shared.addOperation(operation, categories: categories)
            operationQueue.addOperation(operation)
        }
    }
}
