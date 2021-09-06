//
//  Operation+Completion.swift
//  Operation+Completion
//
//  Created by pronebird on 06/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

extension Operation {

    func addCompletionBlock(_ newBlock: @escaping () -> Void) {
        if let currentBlock = completionBlock {
            completionBlock = {
                currentBlock()
                newBlock()
            }
        } else {
            completionBlock = newBlock
        }
    }

}
