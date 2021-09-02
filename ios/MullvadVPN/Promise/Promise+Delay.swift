//
//  Promise+Delay.swift
//  Promise+Delay
//
//  Created by pronebird on 01/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

extension Promise {

    enum TimerType {
        case deadline
        case walltime

        fileprivate func scheduleTimer(_ timer: DispatchSourceTimer, timeInterval: DispatchTimeInterval) {
            switch self {
            case .deadline:
                timer.schedule(deadline: .now() + timeInterval)
            case .walltime:
                timer.schedule(wallDeadline: .now() + timeInterval)
            }
        }
    }

    func delay(by timeInterval: DispatchTimeInterval, timerType: TimerType) -> Promise<Value> {
        return then { value in
            return Promise { resolver in
                let timer = DispatchSource.makeTimerSource(flags: [], queue: resolver.queue)

                resolver.setCancelHandler {
                    timer.cancel()
                }

                timer.setEventHandler {
                    resolver.resolve(value: value)
                }

                timerType.scheduleTimer(timer, timeInterval: timeInterval)
                timer.activate()
            }
        }
    }
}
