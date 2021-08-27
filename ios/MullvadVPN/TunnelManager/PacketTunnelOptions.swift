//
//  PacketTunnelOptions.swift
//  PacketTunnelOptions
//
//  Created by pronebird on 22/08/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

enum PacketTunnelOptions {
    /// Option key that holds the `NSData` value with `RelaySelectorResult` encoded using `JSONEncoder`.
    /// Used for passing the pre-selected relay in the GUI proocess to the Packet tunnel process.
    static let relaySelectorResult = "relay-selector-result"

    /// Option key that holds the `NSNumber` value, which is when set to `1` indicates that the tunnel was started by
    /// the system.
    /// System automatically provides that flag to the tunnel.
    static let isOnDemand = "is-on-demand"
}
