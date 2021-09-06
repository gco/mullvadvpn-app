//
//  AppStorePaymentManager.swift
//  MullvadVPN
//
//  Created by pronebird on 10/03/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import StoreKit
import Logging

class AppStorePaymentManager: NSObject, SKPaymentTransactionObserver {

    private enum OperationCategory {
        static let sendAppStoreReceipt = "AppStorePaymentManager.sendAppStoreReceipt"
        static let productsRequest = "AppStorePaymentManager.productsRequest"
    }

    enum Error: ChainedError {
        case noAccountSet
        case storePayment(Swift.Error)
        case readReceipt(AppStoreReceipt.Error)
        case sendReceipt(REST.Error)

        var errorDescription: String? {
            switch self {
            case .noAccountSet:
                return "Account is not set"
            case .storePayment:
                return "Store payment error"
            case .readReceipt:
                return "Read recept error"
            case .sendReceipt:
                return "Send receipt error"
            }
        }
    }

    /// A shared instance of `AppStorePaymentManager`
    static let shared = AppStorePaymentManager(queue: SKPaymentQueue.default())

    private let logger = Logger(label: "AppStorePaymentManager")

    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AppStorePaymentManagerQueue"
        return queue
    }()

    private let paymentQueue: SKPaymentQueue

    private var observerList = ObserverList<AnyAppStorePaymentObserver>()
    private let lock = NSRecursiveLock()

    private weak var classDelegate: AppStorePaymentManagerDelegate?
    weak var delegate: AppStorePaymentManagerDelegate? {
        get {
            lock.withCriticalBlock {
                return classDelegate
            }
        }
        set {
            lock.withCriticalBlock {
                classDelegate = newValue
            }
        }
    }

    /// A private hash map that maps each payment to account token
    private var paymentToAccountToken = [SKPayment: String]()

    /// Returns true if the device is able to make payments
    class var canMakePayments: Bool {
        return SKPaymentQueue.canMakePayments()
    }

    init(queue: SKPaymentQueue) {
        self.paymentQueue = queue
    }

    func startPaymentQueueMonitoring() {
        self.logger.debug("Start payment queue monitoring.")
        paymentQueue.add(self)
    }

    // MARK: - SKPaymentTransactionObserver

    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            self.handleTransaction(transaction)
        }
    }

    // MARK: - Payment observation

    func addPaymentObserver<T: AppStorePaymentObserver>(_ observer: T) {
        self.observerList.append(AnyAppStorePaymentObserver(observer))
    }

    func removePaymentObserver<T: AppStorePaymentObserver>(_ observer: T) {
        observerList.remove(AnyAppStorePaymentObserver(observer))
    }

    // MARK: - Account token and payment mapping

    private func associateAccountToken(_ token: String, and payment: SKPayment) {
        lock.withCriticalBlock {
            paymentToAccountToken[payment] = token
        }
    }

    private func deassociateAccountToken(_ payment: SKPayment) -> String? {
        return lock.withCriticalBlock {
            if let accountToken = paymentToAccountToken[payment] {
                paymentToAccountToken.removeValue(forKey: payment)
                return accountToken
            } else {
                return self.classDelegate?
                    .appStorePaymentManager(self, didRequestAccountTokenFor: payment)
            }
        }
    }

    // MARK: - Products and payments

    func requestProducts(with productIdentifiers: Set<AppStoreSubscription>) -> Result<SKProductsResponse, Swift.Error>.Promise {
        return Promise { resolver in
            let productIdentifiers = productIdentifiers.productIdentifiersSet
            let operation = ProductsRequestOperation(productIdentifiers: productIdentifiers) { result in
                resolver.resolve(value: result)
            }
            ExclusivityController.shared.addOperation(operation, categories: [OperationCategory.productsRequest])
            self.operationQueue.addOperation(operation)
        }
    }

    func addPayment(_ payment: SKPayment, for accountToken: String) {
        associateAccountToken(accountToken, and: payment)
        paymentQueue.add(payment)
    }

    func restorePurchases(for accountToken: String) -> Result<REST.CreateApplePaymentResponse, AppStorePaymentManager.Error>.Promise {
        return sendAppStoreReceipt(accountToken: accountToken, forceRefresh: true)
    }

    // MARK: - Private methods

    private func sendAppStoreReceipt(accountToken: String, forceRefresh: Bool) -> Result<REST.CreateApplePaymentResponse, Error>.Promise {
        return AppStoreReceipt.fetch(forceRefresh: forceRefresh)
            .mapError { error in
                self.logger.error(chainedError: error, message: "Failed to fetch the AppStore receipt")

                return .readReceipt(error)
            }
            .mapThen { receiptData in
                return REST.Client.shared.createApplePayment(token: accountToken, receiptString: receiptData)
                    .mapError { error in
                        self.logger.error(chainedError: error, message: "Failed to upload the AppStore receipt")

                        return .sendReceipt(error)
                    }
                    .onSuccess{ response in
                        self.logger.info("AppStore receipt was processed. Time added: \(response.timeAdded), New expiry: \(response.newExpiry)")
                    }
            }
            .run(on: operationQueue, categories: [OperationCategory.sendAppStoreReceipt])
    }

    private func handleTransaction(_ transaction: SKPaymentTransaction) {
        switch transaction.transactionState {
        case .deferred:
            logger.info("Deferred \(transaction.payment.productIdentifier)")

        case .failed:
            logger.error("Failed to purchase \(transaction.payment.productIdentifier): \(transaction.error?.localizedDescription ?? "No error")")

            didFailPurchase(transaction: transaction)

        case .purchased:
            logger.info("Purchased \(transaction.payment.productIdentifier)")

            didFinishOrRestorePurchase(transaction: transaction)

        case .purchasing:
            logger.info("Purchasing \(transaction.payment.productIdentifier)")

        case .restored:
            logger.info("Restored \(transaction.payment.productIdentifier)")

            didFinishOrRestorePurchase(transaction: transaction)

        @unknown default:
            logger.warning("Unknown transactionState = \(transaction.transactionState.rawValue)")
        }
    }

    private func didFailPurchase(transaction: SKPaymentTransaction) {
        paymentQueue.finishTransaction(transaction)

        guard let accountToken = deassociateAccountToken(transaction.payment) else {
            observerList.forEach { (observer) in
                observer.appStorePaymentManager(
                    self,
                    transaction: transaction,
                    accountToken: nil,
                    didFailWithError: .noAccountSet)
            }
            return
        }

        observerList.forEach { (observer) in
            observer.appStorePaymentManager(
                self,
                transaction: transaction,
                accountToken: accountToken,
                didFailWithError: .storePayment(transaction.error!))
        }

    }

    private func didFinishOrRestorePurchase(transaction: SKPaymentTransaction) {
        guard let accountToken = deassociateAccountToken(transaction.payment) else {
            observerList.forEach { (observer) in
                observer.appStorePaymentManager(
                    self,
                    transaction: transaction,
                    accountToken: nil,
                    didFailWithError: .noAccountSet)
            }
            return
        }

        sendAppStoreReceipt(accountToken: accountToken, forceRefresh: false)
            .receive(on: .main)
            .onSuccess { response in
                self.paymentQueue.finishTransaction(transaction)

                self.observerList.forEach { (observer) in
                    observer.appStorePaymentManager(
                        self,
                        transaction: transaction,
                        accountToken: accountToken,
                        didFinishWithResponse: response)
                }
            }
            .onFailure { error in
                self.observerList.forEach { (observer) in
                    observer.appStorePaymentManager(
                        self,
                        transaction: transaction,
                        accountToken: accountToken,
                        didFailWithError: error)
                }
            }
            .observe { _ in }
    }

}
