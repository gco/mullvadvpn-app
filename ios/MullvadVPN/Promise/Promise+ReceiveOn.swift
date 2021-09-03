//
//  Promise+ReceiveOn.swift
//  Promise+ReceiveOn
//
//  Created by pronebird on 22/08/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

extension Promise {
    /// Dispatch the upstream value on another queue.
    func receive(on queue: DispatchQueue) -> Promise<Value> {
        return Promise<Value> { resolver in
            _ = self.observe { completion in
                let work = DispatchWorkItem {
                    resolver.resolve(completion: completion, queue: queue)
                }

                resolver.setCancelHandler {
                    work.cancel()
                }

                queue.async(execute: work)
            }
        }
    }

    /// Dispatch the upstream value on another queue after delay.
    func receive(on queue: DispatchQueue, after deadline: DispatchTime) -> Promise<Value> {
        return Promise<Value> { resolver in
            _ = self.observe { completion in
                queue.asyncAfter(deadline: deadline) {
                    resolver.resolve(completion: completion, queue: queue)
                }
            }
        }
    }
}
