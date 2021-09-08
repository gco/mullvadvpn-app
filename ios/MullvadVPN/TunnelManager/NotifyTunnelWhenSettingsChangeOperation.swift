//
//  NotifyTunnelWhenSettingsChangeOperation.swift
//  NotifyTunnelWhenSettingsChangeOperation
//
//  Created by pronebird on 07/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit

/// Operation that notifies Packet Tunnel Provider when tunnel settings change.
/// This operation waits till the tunnel is connected before sending the IPC message.
/// It drops the message when the tunnel moves to state where it's likely to be unable to handle the message.
class NotifyTunnelWhenSettingsChangeOperation: AsyncOperation {
    private let tunnelProvider: TunnelManager.TunnelProviderManagerType
    private let tunnelIPC: PacketTunnelIpc
    private var statusObserver: NSObjectProtocol?
    private var backgroundTask: UIBackgroundTaskIdentifier?

    init(tunnelProvider aTunnelProvider: TunnelManager.TunnelProviderManagerType) {
        tunnelProvider = aTunnelProvider
        tunnelIPC = PacketTunnelIpc(from: aTunnelProvider)
    }

    override func main() {
        DispatchQueue.main.async {
            // Request background execution to complete the task
            self.backgroundTask = UIApplication.shared
                .beginBackgroundTask(withName: "TunnelManager.NotifyTunnelWhenSettingsChangeOperation") { [weak self] in
                    self?.cancel()
                }

            // Add VPN status observer
            self.statusObserver = NotificationCenter.default
                .addObserver(forName: .NEVPNStatusDidChange,
                             object: self.tunnelProvider.connection,
                             queue: .main) { [weak self] notification in
                    self?.handleTunnelStatus()
            }

            // Handle current status
            self.handleTunnelStatus()
        }
    }

    override func cancel() {
        // Make sure the call happens on main thread
        if Thread.isMainThread {
            // Guard against repeated cancellation
            guard !self.isCancelled else { return }

            super.cancel()

            self.completeOperation()
        } else {
            DispatchQueue.main.async {
                self.cancel()
            }
        }
    }

    private func handleTunnelStatus() {
        let status = tunnelProvider.connection.status

        switch status {
        case .invalid, .disconnected, .disconnecting:
            // Nothing to do.
            completeOperation()

        case .connecting, .reasserting:
            // Wait until transition to connected state.
            break

        case .connected:
            tunnelIPC.reloadTunnelSettings { [weak self] result in
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

        if let backgroundTask = backgroundTask, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)

            self.backgroundTask = nil
        }
    }
}
