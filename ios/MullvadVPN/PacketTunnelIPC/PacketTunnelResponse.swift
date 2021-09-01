//
//  PacketTunnelResponse.swift
//  PacketTunnelResponse
//
//  Created by pronebird on 27/07/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

/// A container type around Packet Tunnel response
struct PacketTunnelResponse<T: Codable>: Codable {
    var value: T
}
