//
//  NotifyTunnelWhenSettingsChangeOperation.swift
//  NotifyTunnelWhenSettingsChangeOperation
//
//  Created by pronebird on 07/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

/// Operation that notifies Packet Tunnel Provider when tunnel settings change.
/// This operation waits till the tunnel is connected before sending the IPC message.
/// It drops the message when the tunnel moves to state where it's likely to be unable to handle the message.
class NotifyTunnelWhenSettingsChangeOperation: AsyncOperation {
    private let tunnelProvider: TunnelManager.TunnelProviderManagerType
    private let tunnelIPC: PacketTunnelIpc
    private var statusObserver: NSObjectProtocol?
    private var senderCancellationToken: PromiseCancellationToken?

    init(tunnelProvider: TunnelManager.TunnelProviderManagerType) {
        self.tunnelProvider = tunnelProvider

        let session = tunnelProvider.connection as! VPNTunnelProviderSessionProtocol
        self.tunnelIPC = PacketTunnelIpc(session: session)
    }

    override func main() {
        DispatchQueue.main.async {
            self.statusObserver = NotificationCenter.default
                .addObserver(forName: .NEVPNStatusDidChange,
                             object: self.tunnelProvider.connection,
                             queue: .main) { [weak self] notification in
                    self?.handleTunnelStatus()
            }

            self.handleTunnelStatus()
        }
    }

    override func cancel() {
        DispatchQueue.main.async {
            // Guard against repeating cancellation
            guard !self.isCancelled else { return }

            super.cancel()

            self.completeOperation()
        }
    }

    private func handleTunnelStatus() {
        let status = tunnelProvider.connection.status

        switch status {
        case .invalid, .disconnected, .disconnecting:
            // Nothing to do.
            completeOperation()

        case .connecting, .reasserting:
            // Wait till transition is completed.
            break

        case .connected:
            tunnelIPC.reloadTunnelSettings()
                .storeCancellationToken(in: &self.senderCancellationToken)
                .receive(on: .main)
                .observe { [weak self] completion in
                    self?.completeOperation()
                }

        @unknown default:
            break
        }
    }

    private func completeOperation() {
        if let statusObserver = statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)

            self.statusObserver = nil
        }

        finish()
    }
}
