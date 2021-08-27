//
//  SimulatorTunnelProviderHost.swift
//  MullvadVPN
//
//  Created by pronebird on 10/02/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

#if targetEnvironment(simulator)

import Foundation
import Network
import NetworkExtension
import Logging

class SimulatorTunnelProviderHost: SimulatorTunnelProviderDelegate {

    private var connectionInfo: TunnelConnectionInfo?
    private let providerLogger = Logger(label: "SimulatorTunnelProviderHost")
    private let dispatchQueue = DispatchQueue(label: "SimulatorTunnelProviderHostQueue")

    override func startTunnel(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            let appSelectorResult = (options?[PacketTunnelOptions.relaySelectorResult] as? Data).map { data in
                return try! JSONDecoder().decode(RelaySelectorResult.self, from: data)
            }

            if let appSelectorResult = appSelectorResult {
                self.connectionInfo = appSelectorResult.tunnelConnectionInfo
            } else {
                self.connectionInfo = self.pickRelay()?.tunnelConnectionInfo
            }

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.connectionInfo = nil

            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        PacketTunnelIpcHandler.decodeRequest(messageData: messageData)
            .asPromise()
            .receive(on: dispatchQueue)
            .onFailure { error in
                self.providerLogger.error(chainedError: error, message: "Failed to decode the IPC request.")
            }
            .success()
            .mapThen(defaultValue: nil) { request in
                switch request {
                case .tunnelConnectionInfo:
                    return PacketTunnelIpcHandler.encodeResponse(self.connectionInfo)
                        .asPromise()
                        .onFailure { error in
                            self.providerLogger.error(chainedError: error, message: "Failed to encode tunnel connection info IPC response.")
                        }
                        .success()

                case .reloadTunnelSettings:
                    self.reasserting = true
                    self.connectionInfo = self.pickRelay()?.tunnelConnectionInfo
                    self.reasserting = false

                    return .resolved(nil)
                }
            }
            .observe { completion in
                completionHandler?(completion.unwrappedValue ?? nil)
            }
    }

    private func replyAppMessage<T: Codable>(_ response: T, completionHandler: ((Data?) -> Void)?) {
        switch PacketTunnelIpcHandler.encodeResponse(response) {
        case .success(let data):
            completionHandler?(data)

        case .failure(let error):
            self.providerLogger.error(chainedError: error)
            completionHandler?(nil)
        }
    }

    private func pickRelay() -> RelaySelectorResult? {
        guard let result = RelayCacheTracker.shared.read().await().unwrappedValue else { return nil }

        switch result {
        case .success(let cachedRelays):
            let keychainReference = self.protocolConfiguration.passwordReference!

            switch TunnelSettingsManager.load(searchTerm: .persistentReference(keychainReference)) {
            case .success(let entry):
                return RelaySelector.evaluate(
                    relays: cachedRelays.relays,
                    constraints: entry.tunnelSettings.relayConstraints
                )
            case .failure(let error):
                self.providerLogger.error(chainedError: error, message: "Failed to load tunnel settings when picking relay")

                return nil
            }

        case .failure(let error):
            self.providerLogger.error(chainedError: error, message: "Failed to read relays when picking relay")
            return nil
        }
    }

}

#endif
