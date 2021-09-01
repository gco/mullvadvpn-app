//
//  TunnelConnectionInfo.swift
//  TunnelConnectionInfo
//
//  Created by pronebird on 27/07/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

/// A struct that holds the basic information regarding the tunnel connection
struct TunnelConnectionInfo: Codable, Equatable {
    let ipv4Relay: IPv4Endpoint
    let ipv6Relay: IPv6Endpoint?
    let hostname: String
    let location: Location
}

extension TunnelConnectionInfo: CustomDebugStringConvertible {
    var debugDescription: String {
        return "{ ipv4Relay: \(String(reflecting: ipv4Relay)), " +
               "ipv6Relay: \(String(reflecting: ipv6Relay)), " +
               "hostname: \(String(reflecting: hostname))," +
               "location: \(String(reflecting: location)) }"
    }
}
