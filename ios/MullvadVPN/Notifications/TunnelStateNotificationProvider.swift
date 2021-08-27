//
//  TunnelStateNotificationProvider.swift
//  TunnelStateNotificationProvider
//
//  Created by pronebird on 20/08/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

class TunnelStateNotificationProvider: NotificationProvider, InAppNotificationProvider, TunnelObserver {
    override var identifier: String {
        return "net.mullvad.MullvadVPN.TunnelStateNotificationProvider"
    }

    private var lastError: TunnelManager.Error?

    private var tunnelState: TunnelState? {
        didSet {
            invalidate()
        }
    }

    var notificationDescriptor: InAppNotificationDescriptor? {
        if let lastError = lastError {
            return InAppNotificationDescriptor(
                identifier: identifier,
                style: .error,
                title: "Tunnel failure",
                body: lastError.errorChainDescription ?? "No error description provided."
            )
        }

        switch tunnelState {
        case .pendingReconnect:
            return InAppNotificationDescriptor(identifier: identifier, style: .success, title: "VPN status", body: "Pending reconnect...")

        case .connecting(let tunnelConnectionInfo):
            if let tunnelConnectionInfo = tunnelConnectionInfo {
                return InAppNotificationDescriptor(identifier: identifier, style: .success, title: "VPN status", body: "Connecting to \(tunnelConnectionInfo.hostname)...")
            } else {
                return InAppNotificationDescriptor(identifier: identifier, style: .success, title: "VPN status", body: "Connecting...")
            }

        case .connected(let tunnelConnectionInfo):
            return InAppNotificationDescriptor(identifier: identifier, style: .success, title: "VPN status", body: "Connected to \(tunnelConnectionInfo.hostname).")

        case .disconnecting(let actionAfterDisconnect):
            return InAppNotificationDescriptor(identifier: identifier, style: .success, title: "VPN status", body: "Disconnecting and then \(actionAfterDisconnect)")

        case .disconnected:
            return InAppNotificationDescriptor(identifier: identifier, style: .success, title: "VPN status", body: "Disconnected.")

        case .reconnecting(let tunnelConnectionInfo):
            return InAppNotificationDescriptor(identifier: identifier, style: .success, title: "VPN status", body: "Reconnecting to \(tunnelConnectionInfo.hostname)...")

        case .none:
            return nil
        }
    }

    override init() {
        super.init()

        TunnelManager.shared.addObserver(self)
        tunnelState = TunnelManager.shared.tunnelState
    }

    func tunnelManager(_ manager: TunnelManager, didUpdateTunnelState tunnelState: TunnelState) {
        DispatchQueue.main.async {
            if case .connecting = tunnelState {
                self.lastError = nil
            }
            self.tunnelState = tunnelState
            self.invalidate()
        }
    }

    func tunnelManager(_ manager: TunnelManager, didUpdateTunnelSettings tunnelSettings: TunnelSettings?, accountToken: String?) {
        // no-op
    }

    func tunnelManager(_ manager: TunnelManager, didFailWithError error: TunnelManager.Error) {
        DispatchQueue.main.async {
            self.lastError = error
            self.invalidate()
        }
    }

    
}
