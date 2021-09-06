//
//  PresentAlertOperation.swift
//  PresentAlertOperation
//
//  Created by pronebird on 06/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import UIKit

class PresentAlertOperation: AsyncOperation {
    private let alertController: UIAlertController
    private let presentingController: UIViewController
    private let presentCompletion: (() -> Void)?

    init(alertController: UIAlertController, presentingController: UIViewController, presentCompletion: (() -> Void)? = nil) {
        self.alertController = alertController
        self.presentingController = presentingController
        self.presentCompletion = presentCompletion

        super.init()
    }

    override func main() {
        DispatchQueue.main.async {
            NotificationCenter.default
                .addObserver(self, selector: #selector(self.alertControllerDidDismiss(_:)),
                             name: AlertPresenter.alertControllerDidDismissNotification,
                             object: self.alertController)

            self.presentingController.present(self.alertController, animated: true, completion: self.presentCompletion)
        }
    }

    @objc private func alertControllerDidDismiss(_ note: Notification) {
        finish()
    }
}
