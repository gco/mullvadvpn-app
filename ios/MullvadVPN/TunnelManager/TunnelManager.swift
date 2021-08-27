//
//  TunnelManager.swift
//  MullvadVPN
//
//  Created by pronebird on 25/09/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import NetworkExtension
import Logging
import WireGuardKit

/// A class that provides a convenient interface for VPN tunnels configuration, manipulation and
/// monitoring.
class TunnelManager {

    /// An error emitted by all public methods of TunnelManager
    enum Error: ChainedError {
        /// Account token is not set
        case missingAccount

        /// A failure to start the VPN tunnel via system call
        case startVPNTunnel(Swift.Error)

        /// A failure to load the system VPN configurations created by the app
        case loadAllVPNConfigurations(Swift.Error)

        /// A failure to save the system VPN configuration
        case saveVPNConfiguration(Swift.Error)

        /// A failure to reload the system VPN configuration
        case reloadVPNConfiguration(Swift.Error)

        /// A failure to remove the system VPN configuration
        case removeVPNConfiguration(Swift.Error)

        /// A failure to perform a recovery (by removing the VPN configuration) when a corrupt
        /// VPN configuration is detected.
        case removeInconsistentVPNConfiguration(Swift.Error)

        /// A failure to read tunnel settings
        case readTunnelSettings(TunnelSettingsManager.Error)

        /// A failure to read relays cache
        case readRelays(RelayCacheError)

        /// A failure to find a relay satisfying the given constraints
        case cannotSatisfyRelayConstraints

        /// A failure to add the tunnel settings
        case addTunnelSettings(TunnelSettingsManager.Error)

        /// A failure to update the tunnel settings
        case updateTunnelSettings(TunnelSettingsManager.Error)

        /// A failure to remove the tunnel settings from Keychain
        case removeTunnelSettings(TunnelSettingsManager.Error)

        /// A failure to migrate tunnel settings
        case migrateTunnelSettings(TunnelSettingsManager.Error)

        /// Unable to obtain the persistent keychain reference for the tunnel settings
        case obtainPersistentKeychainReference(TunnelSettingsManager.Error)

        /// A failure to push the public WireGuard key
        case pushWireguardKey(RestError)

        /// A failure to replace the public WireGuard key
        case replaceWireguardKey(RestError)

        /// A failure to remove the public WireGuard key
        case removeWireguardKey(RestError)

        /// A failure to verify the public WireGuard key
        case verifyWireguardKey(RestError)

        var errorDescription: String? {
            switch self {
            case .missingAccount:
                return "Missing account token"
            case .startVPNTunnel:
                return "Failed to start the VPN tunnel"
            case .loadAllVPNConfigurations:
                return "Failed to load the system VPN configurations"
            case .saveVPNConfiguration:
                return "Failed to save the system VPN configuration"
            case .reloadVPNConfiguration:
                return "Failed to reload the system VPN configuration"
            case .removeVPNConfiguration:
                return "Failed to remove the system VPN configuration"
            case .removeInconsistentVPNConfiguration:
                return "Failed to remove the inconsistent VPN tunnel"
            case .readTunnelSettings:
                return "Failed to read the tunnel settings"
            case .readRelays:
                return "Failed to read relays"
            case .cannotSatisfyRelayConstraints:
                return "Failed to satisfy the relay constraints"
            case .addTunnelSettings:
                return "Failed to add the tunnel settings"
            case .updateTunnelSettings:
                return "Failed to update the tunnel settings"
            case .removeTunnelSettings:
                return "Failed to remove the tunnel settings"
            case .migrateTunnelSettings:
                return "Failed to migrate the tunnel settings"
            case .obtainPersistentKeychainReference:
                return "Failed to obtain the persistent keychain reference"
            case .pushWireguardKey:
                return "Failed to push the WireGuard key to server"
            case .replaceWireguardKey:
                return "Failed to replace the WireGuard key on server"
            case .removeWireguardKey:
                return "Failed to remove the WireGuard key from server"
            case .verifyWireguardKey:
                return "Failed to verify the WireGuard key on server"
            }
        }
    }

    // Switch to stabs on simulator
    #if targetEnvironment(simulator)
    typealias TunnelProviderManagerType = SimulatorTunnelProviderManager
    #else
    typealias TunnelProviderManagerType = NETunnelProviderManager
    #endif

    static let shared = TunnelManager()

    // MARK: - Internal variables

    private let logger = Logger(label: "TunnelManager")
    private let stateQueue = DispatchQueue(label: "TunnelManagerStateQueue")
    private let tunnelQueue = DispatchQueue(label: "TunnelManagerOperationQueue")

    private let rest = MullvadRest()
    private var tunnelProvider: TunnelProviderManagerType?
    private var tunnelIpc: PacketTunnelIpc?
    private var tunnelConnectionInfoToken: PromiseCancellationToken?

    private let stateLock = NSLock()
    private let observerList = ObserverList<AnyTunnelObserver>()

    /// A VPN connection status observer
    private var connectionStatusObserver: NSObjectProtocol?

    struct TunnelInfo {
        /// Mullvad account token
        var token: String

        /// Tunnel settings
        var tunnelSettings: TunnelSettings
    }

    private(set) var tunnelInfo: TunnelInfo? {
        set {
            stateLock.withCriticalBlock {
                _tunnelInfo = newValue

                observerList.forEach { (observer) in
                    observer.tunnelManager(self, didUpdateTunnelSettings: newValue?.tunnelSettings, accountToken: newValue?.token)
                }
            }
        }
        get {
            return stateLock.withCriticalBlock {
                return _tunnelInfo
            }
        }
    }

    private var _tunnelInfo: TunnelInfo?
    private var _tunnelState = TunnelState.disconnected

    private init() {}

    // MARK: - Public

    private(set) var tunnelState: TunnelState {
        set {
            stateLock.withCriticalBlock {
                guard _tunnelState != newValue else { return }

                logger.info("Set tunnel state: \(newValue)")

                _tunnelState = newValue

                observerList.forEach { (observer) in
                    observer.tunnelManager(self, didUpdateTunnelState: newValue)
                }
            }
        }
        get {
            return stateLock.withCriticalBlock {
                return _tunnelState
            }
        }
    }

    /// Initialize the TunnelManager with the tunnel from the system.
    ///
    /// The given account token is used to ensure that the system tunnel was configured for the same
    /// account. The system tunnel is removed in case of inconsistency.
    func loadTunnel(accountToken: String?) -> Result<(), TunnelManager.Error>.Promise {
        let promise = TunnelProviderManagerType.loadAllFromPreferences()
            .receive(on: self.stateQueue)
            .mapError { error in
                return .loadAllVPNConfigurations(error)
            }.mapThen { tunnels in
                return Result.Promise { resolver in
                    self.initializeManager(accountToken: accountToken, tunnels: tunnels) { result in
                        resolver.resolve(value: result)
                    }
                }
            }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)

        return promise
    }

    /// Refresh tunnel state.
    /// Use this method to update the tunnel state when app transitions from suspended to active
    /// state.
    func refreshTunnelState() {
        stateQueue.async {
            self.updateTunnelState()
        }
    }

    func startTunnel() {
        _ = Result<(), Error>.Promise { resolver in
            guard let tunnelInfo = self.tunnelInfo else {
                resolver.resolve(value: .failure(.missingAccount))
                return
            }

            switch self.tunnelState {
            case .disconnecting(.nothing):
                self.tunnelState = .disconnecting(.reconnect)
                resolver.resolve(value: .success(()))

            case .disconnected, .pendingReconnect:
                RelayCacheTracker.shared.read()
                    .mapError { error in
                        return .readRelays(error)
                    }
                    .receive(on: self.stateQueue)
                    .flatMap { cachedRelays in
                        return RelaySelector.evaluate(
                            relays: cachedRelays.relays,
                            constraints: tunnelInfo.tunnelSettings.relayConstraints
                        ).map { .success($0) } ?? .failure(.cannotSatisfyRelayConstraints)
                    }
                    .mapThen { selectorResult in
                        return self.makeTunnelProvider(accountToken: tunnelInfo.token)
                            .receive(on: self.stateQueue)
                            .flatMap { tunnelProvider in
                                self.setTunnelProvider(tunnelProvider: tunnelProvider)

                                let options: [String: NSObject] =  [
                                    PacketTunnelOptions.relaySelectorResult: try! JSONEncoder().encode(selectorResult) as NSData
                                ]

                                self.tunnelState = .connecting(selectorResult.tunnelConnectionInfo)

                                return Result { try tunnelProvider.connection.startVPNTunnel(options: options) }
                                    .mapError { error in
                                        return .startVPNTunnel(error)
                                    }
                            }
                    }.observe { completion in
                        resolver.resolve(completion: completion)
                    }

            default:
                // Do not attempt to start the tunnel in all other cases.
                resolver.resolve(value: .success(()))
            }
        }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)
            .onFailure { error in
                self.sendFailureToObservers(error)
            }
    }

    func stopTunnel() {
        _ = Result<(), Error>.Promise { resolver in
            guard let tunnelProvider = self.tunnelProvider else {
                resolver.resolve(value: .failure(.missingAccount))
                return
            }

            switch self.tunnelState {
            case .disconnecting(.reconnect):
                self.tunnelState = .disconnecting(.nothing)
                resolver.resolve(value: .success(()))

            case .connected, .connecting:
                // Disable on-demand when stopping the tunnel to prevent it from coming back up
                tunnelProvider.isOnDemandEnabled = false

                tunnelProvider.saveToPreferences()
                    .mapError { error in
                        return Error.saveVPNConfiguration(error)
                    }
                    .observe { completion in
                        tunnelProvider.connection.stopVPNTunnel()
                        resolver.resolve(completion: completion)
                    }

            default:
                resolver.resolve(value: .success(()))
            }
        }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)
            .onFailure { error in
                self.sendFailureToObservers(error)
            }
    }

    func reconnectTunnel() {
        _ = Result<(), Error>.Promise { resolver in
            guard let tunnelIpc = self.tunnelIpc else {
                resolver.resolve(value: .success(()))
                return
            }

            switch self.tunnelState {
            case .connected, .reconnecting:
                tunnelIpc.reloadTunnelSettings()
                    .onFailure { error in
                        self.logger.error(chainedError: error, message: "Failed to reconnect the tunnel")
                    }
                    .flatMapError { _ in
                        return .success(())
                    }
                    .observe { completion in
                        resolver.resolve(completion: completion)
                    }
            case .pendingReconnect, .connecting, .disconnecting, .disconnected:
                self.logger.debug("Ignore request to reconnect the tunnel in \(self.tunnelState)")

                resolver.resolve(value: .success(()))
            }
        }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)
            .observe { _ in }
    }

    func setAccount(accountToken: String) -> Result<(), Error>.Promise {
        let promise = Result<(), Error>.Promise { resolver in
            _ = Self.makeTunnelSettings(accountToken: accountToken)
                .asPromise()
                .mapThen { tunnelSettings -> Result<TunnelSettings, Error>.Promise in
                    let interfaceSettings = tunnelSettings.interface
                    guard interfaceSettings.addresses.isEmpty else {
                        return .success(tunnelSettings)
                    }

                    // Push wireguard key if addresses were not received yet
                    return self.pushWireguardKeyAndUpdateSettings(accountToken: accountToken, publicKey: interfaceSettings.publicKey)
                }
                .receive(on: self.stateQueue)
                .onSuccess { tunnelSettings in
                    self.tunnelInfo = TunnelInfo(token: accountToken, tunnelSettings: tunnelSettings)
                }
                .setOutput(())
                .observe { completion in
                    resolver.resolve(completion: completion)
                }
        }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)

        return promise
    }

    /// Remove the account token and remove the active tunnel
    func unsetAccount() ->  Result<(), Error>.Promise {
        let promise = Result<(), Error>.Promise { resolver in
            guard let tunnelInfo = self.tunnelInfo else {
                resolver.resolve(value: .failure(.missingAccount))
                return
            }

            let publicKey = tunnelInfo.tunnelSettings.interface.publicKey

            self.removeWireguardKeyFromServer(accountToken: tunnelInfo.token, publicKey: publicKey)
                .receive(on: self.stateQueue)
                .then { result -> Result<(), Error>.Promise in
                    switch result {
                    case .success(let isRemoved):
                        self.logger.warning("Removed the WireGuard key from server: \(isRemoved)")

                    case .failure(let error):
                        self.logger.error(chainedError: error, message: "Unset account error")
                    }

                    // Unregister from receiving the tunnel state changes
                    self.unregisterConnectionObserver()
                    self.tunnelConnectionInfoToken = nil
                    self.tunnelState = .disconnected
                    self.tunnelIpc = nil

                    // Remove settings from Keychain
                    if case .failure(let error) = TunnelSettingsManager.remove(searchTerm: .accountToken(tunnelInfo.token)) {
                        // Ignore Keychain errors because that normally means that the Keychain
                        // configuration was already removed and we shouldn't be blocking the
                        // user from logging out
                        self.logger.error(
                            chainedError: error,
                            message: "Failure to remove tunnel setting from keychain when unsetting user account"
                        )
                    }

                    self.tunnelInfo = nil

                    guard let tunnelProvider = self.tunnelProvider else {
                        return .success(())
                    }

                    self.tunnelProvider = nil

                    // Remove VPN configuration
                    return tunnelProvider.removeFromPreferences()
                        .flatMapError { error -> Result<(), Error> in
                            // Ignore error but log it
                            self.logger.error(
                                chainedError: Error.removeVPNConfiguration(error),
                                message: "Failure to remove system VPN configuration when unsetting user account."
                            )

                            return .success(())
                        }
                }
                .observe { completion in
                    resolver.resolve(completion: completion)
                }
        }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)

        return promise
    }

    func verifyPublicKey() -> Result<Bool, Error>.Promise {
        return Promise { resolver in
            guard let tunnelInfo = self.tunnelInfo else {
                resolver.resolve(value: .failure(.missingAccount))
                return
            }

            let payload = PublicKeyPayload(
                pubKey: tunnelInfo.tunnelSettings.interface.publicKey.rawValue,
                payload: TokenPayload(token: tunnelInfo.token, payload: EmptyPayload())
            )

            self.rest.getWireguardKey()
                .promise(payload: payload)
                .map { _ in
                    return true
                }
                .flatMapError { error in
                    if case .server(.pubKeyNotFound) = error {
                        return .success(false)
                    } else {
                        return .failure(.verifyWireguardKey(error))
                    }
                }.observe { completion in
                    resolver.resolve(completion: completion)
                }
        }
        .schedule(on: stateQueue)
    }

    func regeneratePrivateKey() -> Result<(), Error>.Promise {
        let promise = Result<(), Error>.Promise { resolver in
            guard let tunnelInfo = self.tunnelInfo else {
                resolver.resolve(value: .failure(.missingAccount))
                return
            }

            let newPrivateKey = PrivateKeyWithMetadata()
            let oldPublicKeyMetadata = tunnelInfo.tunnelSettings.interface
                .privateKey
                .publicKeyWithMetadata

            self.replaceWireguardKeyAndUpdateSettings(accountToken: tunnelInfo.token, oldPublicKey: oldPublicKeyMetadata, newPrivateKey: newPrivateKey)
                .mapThen { newTunnelSettings in
                    self.tunnelInfo?.tunnelSettings = newTunnelSettings

                    return self.tunnelIpc.asPromise()
                        .mapThen(defaultValue: .success(())) { ipc in
                            return ipc.reloadTunnelSettings()
                                .onFailure { error in
                                    self.logger.error(chainedError: error, message: "Failed to reload tunnel settings after regenerating the key")
                                }
                                .flatMapError { error in
                                    return .success(())
                                }
                        }
                }
                .observe { completion in
                    resolver.resolve(completion: completion)
                }
        }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)

        return promise
    }

    func setRelayConstraints(_ newConstraints: RelayConstraints) -> Result<(), Error>.Promise {
        let promise = Result<(), Error>.Promise { resolver in
            self.updateTunnelSettings { tunnelSettings in
                tunnelSettings.relayConstraints = newConstraints
            }.observe { completion in
                resolver.resolve(completion: completion)
            }
        }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)

        return promise
    }

    func setDNSSettings(_ newDNSSettings: DNSSettings) -> Result<(), TunnelManager.Error>.Promise {
        let promise = Result<(), Error>.Promise { resolver in
            self.updateTunnelSettings { tunnelSettings in
                tunnelSettings.interface.dnsSettings = newDNSSettings
            }
            .observe { completion in
                resolver.resolve(completion: completion)
            }
        }
            .schedule(on: stateQueue)
            .block(on: tunnelQueue)

        return promise
    }

    private func updateTunnelSettings(block: @escaping (inout TunnelSettings) -> Void) -> Result<(), Error>.Promise {
        guard let tunnelInfo = self.tunnelInfo else {
            return .failure(.missingAccount)
        }

        return Self.updateTunnelSettings(accountToken: tunnelInfo.token, block: block)
            .asPromise()
            .mapThen { newTunnelSettings in
                self.tunnelInfo?.tunnelSettings = newTunnelSettings

                return self.tunnelIpc.asPromise()
                    .mapThen(defaultValue: .success(())) { ipc in
                        return ipc.reloadTunnelSettings()
                            .onFailure { error in
                                self.logger.error(chainedError: error, message: "Failed to reload tunnel settings after updating tunnel settings")
                            }
                            .flatMapError { error in
                                return .success(())
                            }
                    }
            }
    }

    // MARK: - Tunnel observeration

    /// Add tunnel observer.
    /// In order to cancel the observation, either call `removeTunnelObserver(_:)` or simply release
    /// the observer.
    func addObserver<T: TunnelObserver>(_ observer: T) {
        observerList.append(AnyTunnelObserver(observer))
    }

    /// Remove tunnel observer.
    func removeObserver<T: TunnelObserver>(_ observer: T) {
        observerList.remove(AnyTunnelObserver(observer))
    }

    // MARK: - Private methods

    private func initializeManager(accountToken: String?, tunnels: [TunnelProviderManagerType]?, completionHandler: @escaping (Result<(), TunnelManager.Error>) -> Void) {
        // Migrate the tunnel settings if needed
        let migrationResult = accountToken.map { self.migrateTunnelSettings(accountToken: $0) }
        switch migrationResult {
        case .success, .none:
            break
        case .failure(let migrationError):
            completionHandler(.failure(migrationError))
            return
        }

        switch (tunnels?.first, accountToken) {
        // Case 1: tunnel exists and account token is set.
        // Verify that tunnel can access the configuration via the persistent keychain reference
        // stored in `passwordReference` field of VPN configuration.
        case (.some(let tunnelProvider), .some(let accountToken)):
            let verificationResult = self.verifyTunnel(tunnelProvider: tunnelProvider, expectedAccountToken: accountToken)
            let tunnelSettingsResult = Self.loadTunnelSettings(accountToken: accountToken)

            switch (verificationResult, tunnelSettingsResult) {
            case (.success(true), .success(let keychainEntry)):
                self.tunnelInfo = TunnelInfo(token: accountToken, tunnelSettings: keychainEntry.tunnelSettings)
                self.setTunnelProvider(tunnelProvider: tunnelProvider)

                completionHandler(.success(()))

            // Remove the tunnel when failed to verify it but successfuly loaded the tunnel
            // settings.
            case (.failure(let verificationError), .success(let keychainEntry)):
                self.logger.error(chainedError: verificationError, message: "Failed to verify the tunnel but successfully loaded the tunnel settings. Removing the tunnel.")

                // Identical code path as the case below.
                fallthrough

            // Remove the tunnel with corrupt configuration.
            // It will be re-created upon the first attempt to connect the tunnel.
            case (.success(false), .success(let keychainEntry)):
                tunnelProvider.removeFromPreferences()
                    .receive(on: self.stateQueue)
                    .mapError { error in
                        return .removeInconsistentVPNConfiguration(error)
                    }
                    .onSuccess { _ in
                        self.tunnelInfo = TunnelInfo(token: accountToken, tunnelSettings: keychainEntry.tunnelSettings)
                    }
                    .observe { completion in
                        completionHandler(completion.unwrappedValue!)
                    }

            // Remove the tunnel when failed to verify the tunnel and load tunnel settings.
            case (.failure(let verificationError), .failure(_)):
                self.logger.error(chainedError: verificationError, message: "Failed to verify the tunnel and load tunnel settings. Removing the tunnel.")

                tunnelProvider.removeFromPreferences()
                    .mapError { error in
                        return .removeInconsistentVPNConfiguration(error)
                    }
                    .flatMap { _ in
                        return .failure(verificationError)
                    }
                    .observe { completion in
                        completionHandler(completion.unwrappedValue!)
                    }

            // Remove the tunnel when the app is not able to read tunnel settings
            case (.success(_), .failure(let settingsReadError)):
                self.logger.error(chainedError: settingsReadError, message: "Failed to load tunnel settings. Removing the tunnel.")

                tunnelProvider.removeFromPreferences()
                    .mapError { error in
                        return .removeInconsistentVPNConfiguration(error)
                    }
                    .flatMap { _ in
                        return .failure(settingsReadError)
                    }
                    .observe { completion in
                        completionHandler(completion.unwrappedValue!)
                    }
            }

        // Case 2: tunnel exists but account token is unset.
        // Remove the orphaned tunnel.
        case (.some(let tunnelProvider), .none):
            tunnelProvider.removeFromPreferences()
                .mapError { error in
                    return .removeInconsistentVPNConfiguration(error)
                }
                .observe { completion in
                    completionHandler(completion.unwrappedValue!)
                }

        // Case 3: tunnel does not exist but the account token is set.
        // Verify that tunnel settings exists in keychain.
        case (.none, .some(let accountToken)):
            switch Self.loadTunnelSettings(accountToken: accountToken) {
            case .success(let keychainEntry):
                self.tunnelInfo = TunnelInfo(token: accountToken, tunnelSettings: keychainEntry.tunnelSettings)

                completionHandler(.success(()))

            case .failure(let error):
                completionHandler(.failure(error))
            }

        // Case 4: no tunnels exist and account token is unset.
        case (.none, .none):
            completionHandler(.success(()))
        }
    }

    private func verifyTunnel(tunnelProvider: TunnelProviderManagerType, expectedAccountToken accountToken: String) -> Result<Bool, Error> {
        // Check that the VPN configuration points to the same account token
        guard let username = tunnelProvider.protocolConfiguration?.username, username == accountToken else {
            logger.warning("The token assigned to the VPN configuration does not match the logged in account.")
            return .success(false)
        }

        // Check that the passwordReference, containing the keychain reference for tunnel
        // configuration, is set.
        guard let keychainReference = tunnelProvider.protocolConfiguration?.passwordReference else {
            logger.warning("VPN configuration is missing the passwordReference.")
            return .success(false)
        }

        // Verify that the keychain reference points to the existing entry in Keychain.
        // Bad reference is possible when migrating the user data from one device to the other.
        return TunnelSettingsManager.exists(searchTerm: .persistentReference(keychainReference))
            .mapError { (error) -> Error in
                logger.error(chainedError: error, message: "Failed to verify the persistent keychain reference for tunnel settings.")

                return Error.readTunnelSettings(error)
            }
    }

    /// Set the instance of the active tunnel and add the tunnel status observer
    private func setTunnelProvider(tunnelProvider: TunnelProviderManagerType) {
        guard self.tunnelProvider != tunnelProvider else {
            return
        }

        // Save the new active tunnel provider
        self.tunnelProvider = tunnelProvider

        // Set up tunnel IPC
        let connection = tunnelProvider.connection
        let session = connection as! VPNTunnelProviderSessionProtocol
        let tunnelIpc = PacketTunnelIpc(session: session)
        self.tunnelIpc = tunnelIpc

        // Register for tunnel connection status changes
        unregisterConnectionObserver()
        connectionStatusObserver = NotificationCenter.default
            .addObserver(forName: .NEVPNStatusDidChange, object: connection, queue: nil) {
                [weak self] (notification) in
                guard let self = self else { return }

                self.stateQueue.async {
                    self.updateTunnelState()
                }
        }

        // Update the existing state
        updateTunnelState()
    }

    private func unregisterConnectionObserver() {
        if let connectionStatusObserver = connectionStatusObserver {
            NotificationCenter.default.removeObserver(connectionStatusObserver)
            self.connectionStatusObserver = nil
        }
    }

    private func pushWireguardKeyAndUpdateSettings(accountToken: String, publicKey: PublicKey) -> Result<TunnelSettings, Error>.Promise
    {
        let payload = TokenPayload(token: accountToken, payload: PushWireguardKeyRequest(pubkey: publicKey.rawValue))

        return rest.pushWireguardKey()
            .promise(payload: payload)
            .mapError { error in
                return .pushWireguardKey(error)
            }
            .flatMap { associatedAddresses in
                return Self.updateTunnelSettings(accountToken: accountToken) { (tunnelSettings) in
                    tunnelSettings.interface.addresses = [
                        associatedAddresses.ipv4Address,
                        associatedAddresses.ipv6Address
                    ]
                }
            }
    }

    private func removeWireguardKeyFromServer(accountToken: String, publicKey: PublicKey) -> Result<Bool, Error>.Promise {
        let payload = PublicKeyPayload(
            pubKey: publicKey.rawValue,
            payload: TokenPayload(token: accountToken, payload: EmptyPayload())
        )

        return rest.deleteWireguardKey().promise(payload: payload)
            .map { _ in
                return true
            }
            .flatMapError { restError -> Result<Bool, Error> in
                if case .server(.pubKeyNotFound) = restError {
                    return .success(false)
                } else {
                    return .failure(.removeWireguardKey(restError))
                }
            }
    }

    private func replaceWireguardKeyAndUpdateSettings(
        accountToken: String,
        oldPublicKey: PublicKeyWithMetadata,
        newPrivateKey: PrivateKeyWithMetadata
    ) -> Result<TunnelSettings, Error>.Promise
    {
        let payload = TokenPayload(
            token: accountToken,
            payload: ReplaceWireguardKeyRequest(
                old: oldPublicKey.publicKey.rawValue,
                new: newPrivateKey.publicKeyWithMetadata.publicKey.rawValue
            )
        )

        return rest.replaceWireguardKey()
            .promise(payload: payload)
            .receive(on: self.stateQueue)
            .mapError { error in
                return .replaceWireguardKey(error)
            }
            .flatMap { associatedAddresses in
                return Self.updateTunnelSettings(accountToken: accountToken) { (tunnelSettings) in
                    tunnelSettings.interface.privateKey = newPrivateKey
                    tunnelSettings.interface.addresses = [
                        associatedAddresses.ipv4Address,
                        associatedAddresses.ipv6Address
                    ]
                }
            }
    }

    /// Update `TunnelState` from `NEVPNStatus`.
    /// Collects the `TunnelConnectionInfo` from the tunnel via IPC if needed before assigning the `tunnelState`
    private func updateTunnelState() {
        dispatchPrecondition(condition: .onQueue(stateQueue))

        guard let connectionStatus = self.tunnelProvider?.connection.status else { return }

        logger.debug("VPN status changed to \(connectionStatus)")
        tunnelConnectionInfoToken = nil

        switch connectionStatus {
        case .connecting:
            switch tunnelState {
            case .connecting(.some(_)):
                logger.debug("Ignore repeating connecting state.")
            default:
                tunnelState = .connecting(nil)
            }

        case .reasserting:
            _ = tunnelIpc?.getTunnelConnectionInfo()
                .receive(on: stateQueue)
                .storeCancellationToken(in: &tunnelConnectionInfoToken)
                .onSuccess { connectionInfo in
                    if let connectionInfo = connectionInfo {
                        self.tunnelState = .reconnecting(connectionInfo)
                    }
                }

        case .connected:
            _ = tunnelIpc?.getTunnelConnectionInfo()
                .receive(on: stateQueue)
                .storeCancellationToken(in: &tunnelConnectionInfoToken)
                .onSuccess { connectionInfo in
                    if let connectionInfo = connectionInfo {
                        self.tunnelState = .connected(connectionInfo)
                    }
                }

        case .disconnected:
            switch tunnelState {
            case .pendingReconnect:
                logger.debug("Ignore disconnected state when pending reconnect.")

            case .disconnecting(.reconnect):
                logger.debug("Restart the tunnel on disconnect.")
                tunnelState = .pendingReconnect
                startTunnel()

            default:
                tunnelState = .disconnected
            }

        case .disconnecting:
            switch tunnelState {
            case .disconnecting:
                break
            default:
                tunnelState = .disconnecting(.nothing)
            }

        case .invalid:
            tunnelState = .disconnected

        @unknown default:
            logger.debug("Unknown NEVPNStatus: \(connectionStatus.rawValue)")
        }
    }

    private func makeTunnelProvider(accountToken: String) -> Result<TunnelProviderManagerType, TunnelManager.Error>.Promise {
        return TunnelProviderManagerType.loadAllFromPreferences()
            .mapError { error -> TunnelManager.Error in
                return .loadAllVPNConfigurations(error)
            }
            .flatMap { tunnels in
                return Self.setupTunnelProvider(accountToken: accountToken, tunnels: tunnels)
            }
            .mapThen { tunnelProvider in
                return tunnelProvider.saveToPreferences()
                    .mapError { error in
                        return .saveVPNConfiguration(error)
                    }
                    .mapThen { _ in
                        // Refresh connection status after saving the tunnel preferences.
                        // Basically it's only necessary to do for new instances of
                        // `NETunnelProviderManager`, but we do that for the existing ones too
                        // for simplicity as it has no side effects.
                        return tunnelProvider.loadFromPreferences()
                            .mapError { error in
                                return .reloadVPNConfiguration(error)
                            }
                    }
                    .setOutput(tunnelProvider)
            }
    }

    private func sendFailureToObservers(_ failure: Error) {
        self.observerList.forEach { observer in
            observer.tunnelManager(self, didFailWithError: failure)
        }
    }

    // MARK: - Private class methods

    private class func loadTunnelSettings(accountToken: String) -> Result<TunnelSettingsManager.KeychainEntry, Error> {
        return TunnelSettingsManager.load(searchTerm: .accountToken(accountToken))
            .mapError { Error.readTunnelSettings($0) }
    }

    private class func updateTunnelSettings(accountToken: String, block: (inout TunnelSettings) -> Void) -> Result<TunnelSettings, Error> {
        return TunnelSettingsManager.update(searchTerm: .accountToken(accountToken), using: block)
            .mapError { Error.updateTunnelSettings($0) }
    }

    /// Retrieve the existing `TunnelSettings` or create the new ones
    private class func makeTunnelSettings(accountToken: String) -> Result<TunnelSettings, TunnelManager.Error> {
        return Self.loadTunnelSettings(accountToken: accountToken)
            .map { $0.tunnelSettings }
            .flatMapError { error in
                if case .readTunnelSettings(.lookupEntry(.itemNotFound)) = error {
                    let defaultConfiguration = TunnelSettings()

                    return TunnelSettingsManager
                        .add(configuration: defaultConfiguration, account: accountToken)
                        .mapError { .addTunnelSettings($0) }
                        .map { defaultConfiguration }
                } else {
                    return .failure(error)
                }
            }
    }

    private class func setupTunnelProvider(accountToken: String ,tunnels: [TunnelProviderManagerType]?) -> Result<TunnelProviderManagerType, Error> {
        // Request persistent keychain reference to tunnel settings
        return TunnelSettingsManager.getPersistentKeychainReference(account: accountToken)
            .map { (passwordReference) -> TunnelProviderManagerType in
                // Get the first available tunnel or make a new one
                let tunnelProvider = tunnels?.first ?? TunnelProviderManagerType()

                let protocolConfig = NETunnelProviderProtocol()
                protocolConfig.providerBundleIdentifier = ApplicationConfiguration.packetTunnelExtensionIdentifier
                protocolConfig.serverAddress = ""
                protocolConfig.username = accountToken
                protocolConfig.passwordReference = passwordReference

                tunnelProvider.isEnabled = true
                tunnelProvider.localizedDescription = "WireGuard"
                tunnelProvider.protocolConfiguration = protocolConfig

                // Enable on-demand VPN, always connect the tunnel when on Wi-Fi or cellular
                let alwaysOnRule = NEOnDemandRuleConnect()
                alwaysOnRule.interfaceTypeMatch = .any
                tunnelProvider.onDemandRules = [alwaysOnRule]
                tunnelProvider.isOnDemandEnabled = true

                return tunnelProvider
            }.mapError { (error) -> Error in
                return .obtainPersistentKeychainReference(error)
            }
    }

    private func migrateTunnelSettings(accountToken: String) -> Result<Bool, Error> {
        let result = TunnelSettingsManager
            .migrateKeychainEntry(searchTerm: .accountToken(accountToken))
            .mapError { (error) -> Error in
                return .migrateTunnelSettings(error)
            }

        switch result {
        case .success(let migrated):
            if migrated {
                self.logger.info("Migrated Keychain tunnel configuration.")
            } else {
                self.logger.info("Tunnel settings are up to date. No migration needed.")
            }

        case .failure(let error):
            self.logger.error(chainedError: error)
        }

        return result
    }

}
