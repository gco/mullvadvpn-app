//
//  Account.swift
//  MullvadVPN
//
//  Created by pronebird on 16/05/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import NetworkExtension
import StoreKit
import Logging

/// A enum holding the `UserDefaults` string keys
private enum UserDefaultsKeys: String {
    case isAgreedToTermsOfService = "isAgreedToTermsOfService"
    case accountToken = "accountToken"
    case accountExpiry = "accountExpiry"
}

protocol AccountObserver: AnyObject {
    func account(_ account: Account, didUpdateExpiry expiry: Date)
    func account(_ account: Account, didLoginWithToken token: String, expiry: Date)
    func accountDidLogout(_ account: Account)
}

/// A type-erasing weak container for `AccountObserver`
private class AnyAccountObserver: AccountObserver, WeakObserverBox, Equatable {
    private(set) weak var inner: AccountObserver?

    init<T: AccountObserver>(_ inner: T) {
        self.inner = inner
    }

    func account(_ account: Account, didUpdateExpiry expiry: Date) {
        inner?.account(account, didUpdateExpiry: expiry)
    }

    func account(_ account: Account, didLoginWithToken token: String, expiry: Date) {
        inner?.account(account, didLoginWithToken: token, expiry: expiry)
    }

    func accountDidLogout(_ account: Account) {
        inner?.accountDidLogout(account)
    }

    static func == (lhs: AnyAccountObserver, rhs: AnyAccountObserver) -> Bool {
        return lhs.inner === rhs.inner
    }
}

/// A class that groups the account related operations
class Account {

    enum Error: ChainedError {
        /// A failure to create the new account token
        case createAccount(RestError)

        /// A failure to verify the account token
        case verifyAccount(RestError)

        /// A failure to configure a tunnel
        case tunnelConfiguration(TunnelManager.Error)
    }

    /// A shared instance of `Account`
    static let shared = Account()

    private let logger = Logger(label: "Account")
    private var observerList = ObserverList<AnyAccountObserver>()

    /// Returns true if user agreed to terms of service, otherwise false
    var isAgreedToTermsOfService: Bool {
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.isAgreedToTermsOfService.rawValue)
    }

    /// Returns the currently used account token
    private(set) var token: String? {
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.accountToken.rawValue)
        }
        get {
            return UserDefaults.standard.string(forKey: UserDefaultsKeys.accountToken.rawValue)
        }
    }

    var formattedToken: String? {
        return token?.split(every: 4).joined(separator: " ")
    }

    /// Returns the account expiry for the currently used account token
    private(set) var expiry: Date? {
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.accountExpiry.rawValue)
        }
        get {
            return UserDefaults.standard.object(forKey: UserDefaultsKeys.accountExpiry.rawValue) as? Date
        }
    }

    private enum ExclusivityCategory {
        case exclusive
    }

    private let rest = MullvadRest()
    private let dispatchQueue = DispatchQueue(label: "AccountQueue")

    var isLoggedIn: Bool {
        return token != nil
    }

    /// Save the boolean flag in preferences indicating that the user agreed to terms of service.
    func agreeToTermsOfService() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.isAgreedToTermsOfService.rawValue)
    }

    func loginWithNewAccount(completionHandler: @escaping (Result<AccountResponse, Error>) -> Void) {
        _ = rest.createAccount()
            .receive(on: .main)
            .onSuccess { response in
                self.setupTunnel(accountToken: response.token, expiry: response.expires) { (result) in
                    if case .success = result {
                        self.observerList.forEach { (observer) in
                            observer.account(self, didLoginWithToken: response.token, expiry: response.expires)
                        }
                    }
                    completionHandler(result.map { response })
                }
            }
            .onFailure { error in
                completionHandler(.failure(.createAccount(error)))
            }
            .block(on: dispatchQueue)
    }

    /// Perform the login and save the account token along with expiry (if available) to the
    /// application preferences.
    func login(with accountToken: String, completionHandler: @escaping (Result<AccountResponse, Error>) -> Void) {
        _ = rest.getAccountExpiry(token: accountToken)
            .receive(on: .main)
            .onSuccess { response in
                self.setupTunnel(accountToken: response.token, expiry: response.expires) { (result) in
                    if case .success = result {
                        self.observerList.forEach { (observer) in
                            observer.account(self, didLoginWithToken: response.token, expiry: response.expires)
                        }
                    }
                    completionHandler(result.map { response })
                }
            }
            .onFailure { error in
                completionHandler(.failure(.verifyAccount(error)))
            }
            .block(on: dispatchQueue)
    }

    /// Perform the logout by erasing the account token and expiry from the application preferences.
    func logout(completionHandler: @escaping (Result<(), Error>) -> Void) {
        _ = TunnelManager.shared.unsetAccount()
            .receive(on: .main)
            .mapError { error in
                return Error.tunnelConfiguration(error)
            }
            .onSuccess { _ in
                self.removeFromPreferences()
                self.observerList.forEach { (observer) in
                    observer.accountDidLogout(self)
                }
            }
            .observe { completion in
                completionHandler(completion.unwrappedValue!)
            }
            .block(on: dispatchQueue)
    }

    /// Forget that user was logged in, but do not attempt to unset account in `TunnelManager`.
    /// This function is used in cases where the tunnel or tunnel settings are corrupt.
    func forget(completionHandler: @escaping () -> Void) {
        dispatchQueue.async {
            DispatchQueue.main.sync {
                self.removeFromPreferences()
                self.observerList.forEach { (observer) in
                    observer.accountDidLogout(self)
                }
                completionHandler()
            }
        }
    }

    func updateAccountExpiry() {
        let makeRequest = ResultOperation { () -> TokenPayload<EmptyPayload>? in
            return self.token.flatMap { (token) in
                return TokenPayload(token: token, payload: EmptyPayload())
            }
        }

        let sendRequest = rest.getAccountExpiry()
            .operation(payload: nil)
            .injectResult(from: makeRequest)

        sendRequest.addDidFinishBlockObserver(queue: .main) { (operation, result) in
            switch result {
            case .success(let response):
                if self.expiry != response.expires {
                    self.expiry = response.expires
                    self.observerList.forEach { (observer) in
                        observer.account(self, didUpdateExpiry: response.expires)
                    }
                }

            case .failure(let error):
                self.logger.error(chainedError: error, message: "Failed to update account expiry")
            }
        }

        exclusivityController.addOperations([makeRequest, sendRequest], categories: [.exclusive])
    }

    private func setupTunnel(accountToken: String, expiry: Date, completionHandler: @escaping (Result<(), Error>) -> Void) {
        TunnelManager.shared.setAccount(accountToken: accountToken)
            .receive(on: .main)
            .mapError { error in
                return Error.tunnelConfiguration(error)
            }
            .onSuccess { _ in
                self.token = accountToken
                self.expiry = expiry
            }
            .observe { completion in
                completionHandler(completion.unwrappedValue!)
            }
    }

    private func removeFromPreferences() {
        let preferences = UserDefaults.standard

        preferences.removeObject(forKey: UserDefaultsKeys.accountToken.rawValue)
        preferences.removeObject(forKey: UserDefaultsKeys.accountExpiry.rawValue)
    }

    // MARK: - Account observation

    func addObserver<T: AccountObserver>(_ observer: T) {
        observerList.append(AnyAccountObserver(observer))
    }

    func removeObserver<T: AccountObserver>(_ observer: T) {
        observerList.remove(AnyAccountObserver(observer))
    }
}

extension Account: AppStorePaymentObserver {

    func startPaymentMonitoring(with paymentManager: AppStorePaymentManager) {
        paymentManager.addPaymentObserver(self)
    }

    func appStorePaymentManager(_ manager: AppStorePaymentManager, transaction: SKPaymentTransaction, accountToken: String?, didFailWithError error: AppStorePaymentManager.Error) {
        // no-op
    }

    func appStorePaymentManager(_ manager: AppStorePaymentManager, transaction: SKPaymentTransaction, accountToken: String, didFinishWithResponse response: CreateApplePaymentResponse) {
        let newExpiry = response.newExpiry

        let operation = AsyncBlockOperation { (finish) in
            DispatchQueue.main.async {
                // Make sure that payment corresponds to the active account token
                if self.token == accountToken, self.expiry != newExpiry {
                    self.expiry = newExpiry
                    self.observerList.forEach { (observer) in
                        observer.account(self, didUpdateExpiry: newExpiry)
                    }
                }

                finish()
            }
        }

        exclusivityController.addOperation(operation, categories: [.exclusive])
    }
}
