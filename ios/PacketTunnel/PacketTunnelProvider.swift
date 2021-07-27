//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  Created by pronebird on 19/03/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import Network
import NetworkExtension
import Logging
import WireGuardKit

class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Tunnel provider logger
    private let providerLogger: Logger

    /// WireGuard adapter logger
    private let tunnelLogger: Logger

    /// Internal queue
    private let dispatchQueue = DispatchQueue(label: "PacketTunnel", qos: .utility)

    /// WireGuard adapter
    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self, logHandler: { [weak self] (logLevel, message) in
            self?.tunnelLogger.log(level: logLevel.loggerLevel, "\(message)")
        })
    }()

    /// Tunnel connection information
    private var tunnelConnection: TunnelConnectionInfo?

    override init() {
        initLoggingSystem(bundleIdentifier: Bundle.main.bundleIdentifier!)

        providerLogger = Logger(label: "PacketTunnelProvider")
        tunnelLogger = Logger(label: "WireGuard")
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        dispatchQueue.async {
            self.providerLogger.info("Start the tunnel")

            switch self.makeConfiguration() {
            case .success(let tunnelConfiguration):
                self.tunnelConnection = tunnelConfiguration.selectorResult.tunnelConnectionInfo

                self.adapter.start(tunnelConfiguration: tunnelConfiguration.wgTunnelConfig) { (error) in
                    self.dispatchQueue.async {
                        let error = error.map { PacketTunnelProviderError.startWireguardAdapter($0) }
                        if let error = error {
                            self.providerLogger.error(chainedError: error)
                        }
                        completionHandler(error)
                    }
                }

            case .failure(let error):
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        dispatchQueue.async {
            self.providerLogger.info("Stop the tunnel. Reason: \(reason)")

            self.tunnelConnection = nil
            self.adapter.stop { (error) in
                self.dispatchQueue.async {
                    if let error = error {
                        let error = PacketTunnelProviderError.stopWireguardAdapter(error)

                        self.providerLogger.error(chainedError: error)
                    } else {
                        self.providerLogger.info("Stopped the tunnel")
                    }
                    completionHandler()
                }
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        dispatchQueue.async {
            let decodeResult = PacketTunnelIpcHandler.decodeRequest(messageData: messageData)
                .mapError { PacketTunnelProviderError.ipcHandler($0) }

            switch decodeResult {
            case .success(let request):
                switch request {
                case .reloadTunnelSettings:
                    self.reloadTunnelSettings { (result) in
                        self.replyAppMessage(result.map { true }, completionHandler: completionHandler)
                    }

                case .tunnelInformation:
                    self.replyAppMessage(.success(self.tunnelConnection), completionHandler: completionHandler)
                }

            case .failure(let error):
                self.replyAppMessage(Result<String, PacketTunnelProviderError>.failure(error), completionHandler: completionHandler)
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }

    override func wake() {
        // Add code here to wake up.
    }

    // MARK: - Private

    private func replyAppMessage<T: Codable>(_ result: Result<T, PacketTunnelProviderError>, completionHandler: ((Data?) -> Void)?) {
        let result = result.flatMap { (response) -> Result<Data, PacketTunnelProviderError> in
            return PacketTunnelIpcHandler.encodeResponse(response: response)
                .mapError { PacketTunnelProviderError.ipcHandler($0) }
        }

        switch result {
        case .success(let data):
            completionHandler?(data)

        case .failure(let error):
            self.providerLogger.error(chainedError: error)
            completionHandler?(nil)
        }
    }

    private func makeConfiguration() -> Result<PacketTunnelConfiguration, PacketTunnelProviderError> {
        if let ref = protocolConfiguration.passwordReference {
            return Self.readTunnelSettings(keychainReference: ref)
                .flatMap { tunnelSettings in
                    return Self.selectRelayEndpoint(relayConstraints: tunnelSettings.relayConstraints)
                        .map { (selectorResult) -> PacketTunnelConfiguration in
                            return PacketTunnelConfiguration(
                                tunnelSettings: tunnelSettings,
                                selectorResult: selectorResult
                            )
                        }
                }
        } else {
            return .failure(.missingKeychainConfigurationReference)
        }
    }

    private func reloadTunnelSettings(completionHandler: @escaping (Result<(), PacketTunnelProviderError>) -> Void) {
        providerLogger.info("Reload tunnel settings")

        switch makeConfiguration() {
        case .success(let packetTunnelConfig):
            tunnelConnection = packetTunnelConfig.selectorResult.tunnelConnectionInfo

            adapter.update(tunnelConfiguration: packetTunnelConfig.wgTunnelConfig) { (error) in
                self.dispatchQueue.async {
                    let result: Result<(), PacketTunnelProviderError>
                    if let error = error {
                        result = .failure(.updateWireguardConfiguration(error))
                    } else {
                        result = .success(())
                    }
                    completionHandler(result)
                }
            }

        case .failure(let error):
            completionHandler(.failure(error))
        }
    }

    /// Read tunnel settings from Keychain
    private class func readTunnelSettings(keychainReference: Data) -> Result<TunnelSettings, PacketTunnelProviderError> {
        return TunnelSettingsManager.load(searchTerm: .persistentReference(keychainReference))
            .mapError { PacketTunnelProviderError.cannotReadTunnelSettings($0) }
            .map { $0.tunnelSettings }
    }

    /// Load relay cache with potential networking to refresh the cache and pick the relay for the
    /// given relay constraints.
    private class func selectRelayEndpoint(relayConstraints: RelayConstraints) -> Result<RelaySelectorResult, PacketTunnelProviderError> {
        let cacheFileURL = RelayCacheIO.defaultCacheFileURL(forSecurityApplicationGroupIdentifier: ApplicationConfiguration.securityGroupIdentifier)!
        let prebundledRelaysURL = RelayCacheIO.preBundledRelaysFileURL!

        return RelayCacheIO.readWithFallback(cacheFileURL: cacheFileURL, preBundledRelaysFileURL: prebundledRelaysURL)
            .mapError { relayCacheError -> PacketTunnelProviderError in
                return .readRelayCache(relayCacheError)
            }
            .flatMap { cachedRelayList -> Result<RelaySelectorResult, PacketTunnelProviderError> in
                if let selectorResult = RelaySelector.evaluate(relays: cachedRelayList.relays, constraints: relayConstraints) {
                    return .success(selectorResult)
                } else {
                    return .failure(.noRelaySatisfyingConstraint)
                }
            }
    }
}

enum PacketTunnelProviderError: ChainedError {
    /// Failure to perform operation in such state
    case invalidTunnelState

    /// Failure to read the relay cache
    case readRelayCache(RelayCacheError)

    /// Failure to satisfy the relay constraint
    case noRelaySatisfyingConstraint

    /// Missing the persistent keychain reference to the tunnel settings
    case missingKeychainConfigurationReference

    /// Failure to read the tunnel settings from Keychain
    case cannotReadTunnelSettings(TunnelSettingsManager.Error)

    /// Failure to start the Wireguard backend
    case startWireguardAdapter(WireGuardAdapterError)

    /// Failure to stop the Wireguard backend
    case stopWireguardAdapter(WireGuardAdapterError)

    /// Failure to update the Wireguard configuration
    case updateWireguardConfiguration(WireGuardAdapterError)

    /// IPC handler failure
    case ipcHandler(PacketTunnelIpcHandler.Error)

    var errorDescription: String? {
        switch self {
        case .invalidTunnelState:
            return "Failure to handle request in such tunnel state"

        case .readRelayCache:
            return "Failure to read the relay cache"

        case .noRelaySatisfyingConstraint:
            return "No relay satisfying the given constraint"

        case .missingKeychainConfigurationReference:
            return "Keychain configuration reference is not set on protocol configuration"

        case .cannotReadTunnelSettings:
            return "Failure to read tunnel settings"

        case .startWireguardAdapter:
            return "Failure to start the WireGuard adapter"

        case .stopWireguardAdapter:
            return "Failure to stop the WireGuard adapter"

        case .updateWireguardConfiguration:
            return "Failure to update the Wireguard configuration"

        case .ipcHandler:
            return "Failure to handle the IPC request"
        }
    }
}

struct PacketTunnelConfiguration {
    var tunnelSettings: TunnelSettings
    var selectorResult: RelaySelectorResult
}

extension PacketTunnelConfiguration {

    var wgTunnelConfig: TunnelConfiguration {
        let mullvadEndpoint = selectorResult.endpoint
        var peers = [mullvadEndpoint.ipv4RelayEndpoint]
        if let ipv6RelayEndpoint = mullvadEndpoint.ipv6RelayEndpoint {
            peers.append(ipv6RelayEndpoint)
        }

        let peerConfigs = peers.compactMap { (endpoint) -> PeerConfiguration in
            let pubKey = PublicKey(rawValue: selectorResult.endpoint.publicKey)!
            var peerConfig = PeerConfiguration(publicKey: pubKey)
            peerConfig.endpoint = endpoint
            peerConfig.allowedIPs = [
                IPAddressRange(from: "0.0.0.0/0")!,
                IPAddressRange(from: "::/0")!
            ]
            return peerConfig
        }

        var interfaceConfig = InterfaceConfiguration(privateKey: tunnelSettings.interface.privateKey.privateKey)
        interfaceConfig.listenPort = 0
        interfaceConfig.dns = dnsServers.map { DNSServer(address: $0) }
        interfaceConfig.addresses = tunnelSettings.interface.addresses

        return TunnelConfiguration(name: nil, interface: interfaceConfig, peers: peerConfigs)
    }

    var dnsServers: [IPAddress] {
        let mullvadEndpoint = selectorResult.endpoint
        let dnsSettings = tunnelSettings.interface.dnsSettings

        switch (dnsSettings.blockAdvertising, dnsSettings.blockTracking) {
        case (true, false):
            return [IPv4Address("100.64.0.1")!]
        case (false, true):
            return [IPv4Address("100.64.0.2")!]
        case (true, true):
            return [IPv4Address("100.64.0.3")!]
        case (false, false):
            return [mullvadEndpoint.ipv4Gateway, mullvadEndpoint.ipv6Gateway]
        }
    }
}

extension WireGuardLogLevel {
    var loggerLevel: Logger.Level {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}

extension MullvadEndpoint {
    var ipv4RelayEndpoint: Endpoint {
        return Endpoint(host: .ipv4(ipv4Relay.ip), port: .init(integerLiteral: ipv4Relay.port))
    }

    var ipv6RelayEndpoint: Endpoint? {
        guard let ipv6Relay = ipv6Relay else { return nil }

        return Endpoint(host: .ipv6(ipv6Relay.ip), port: .init(integerLiteral: ipv6Relay.port))
    }
}
