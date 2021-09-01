//
//  Promise+Retry.swift
//  Promise+Retry
//
//  Created by pronebird on 01/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation
import Logging

enum PromiseWaitStrategy {
    case immediate
    case constant(TimeInterval)

    var iterator: AnyIterator<TimeInterval> {
        switch self {
        case .immediate:
            return AnyIterator { .zero }
        case .constant(let constant):
            return AnyIterator { constant }
        }
    }
}

struct PromiseRetryStrategy {
    var maxRetries: Int
    var waitStrategy: PromiseWaitStrategy
    var waitTimerType: PromiseDelayTimerType
}

extension Promise where Value: AnyResult {
    func retry<NewSuccess>(strategy: PromiseRetryStrategy, promiseProducer: @escaping (Success) -> Result<NewSuccess, Failure>.Promise) -> Result<NewSuccess, Failure>.Promise {
        return mapThen { value in
            return Result<NewSuccess, Failure>.Promise { resolver in
                let retry = PromiseRetry(strategy: strategy, promiseProducer: {
                    return promiseProducer(value)
                }, onFinishRetry: { completion in
                    resolver.resolve(completion: completion)
                })

                resolver.setCancelHandler {
                    retry.cancel()
                }

                retry.start()
            }
        }
    }

}

fileprivate class PromiseRetry<Value: AnyResult> {

    private var retry = 0
    private var cancellationTokens: [PromiseCancellationToken] = []
    private var lastCompletion: PromiseCompletion<Value> = .cancelled

    private let strategy: PromiseRetryStrategy
    private let promiseProducer: () -> Promise<Value>
    private var onFinishRetry: ((PromiseCompletion<Value>) -> Void)
    private let lock = NSRecursiveLock()

    init(strategy: PromiseRetryStrategy, promiseProducer: @escaping () -> Promise<Value>, onFinishRetry: @escaping (PromiseCompletion<Value>) -> Void) {
        self.strategy = strategy
        self.promiseProducer = promiseProducer
        self.onFinishRetry = onFinishRetry
    }

    func start() {
        lock.withCriticalBlock {
            guard let promise = nextPromise() else {
                onFinishRetry(self.lastCompletion)
                return
            }

            cancellationTokens.removeAll()

            _ = promise
                .storeCancellationToken(in: &cancellationTokens)
                .observe { [weak self] completion in
                    guard let self = self else { return }

                    switch completion {
                    case .finished(let result):
                        switch result.asConcreteType() {
                        case .success:
                            self.onFinishRetry(completion)

                        case .failure:
                            self.lock.withCriticalBlock {
                                self.lastCompletion = completion
                                self.start()
                            }
                        }

                    case .cancelled:
                        self.onFinishRetry(completion)
                    }
                }
        }
    }

    func cancel() {
        lock.withCriticalBlock {
            cancellationTokens.removeAll()
        }
    }

    private func nextPromise() -> Promise<Value>? {
        return lock.withCriticalBlock {
            guard retry < strategy.maxRetries else {
                return nil
            }

            defer { retry += 1 }

            if retry > 0 {
                guard let delay = self.strategy.waitStrategy.iterator.next() else {
                    return nil
                }

                let timeInterval = DispatchTimeInterval.milliseconds(Int(delay * 1000))

                return Promise.resolved(())
                    .delay(by: timeInterval, timerType: self.strategy.waitTimerType)
                    .storeCancellationToken(in: &cancellationTokens)
                    .then { _ in
                        return self.promiseProducer()
                    }
            } else {
                return promiseProducer()
            }
        }
    }
}
