//
//  RelayCacheError.swift
//  RelayCacheError
//
//  Created by pronebird on 27/07/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

/// Error emitted by read and write functions
enum RelayCacheError: ChainedError {
    case readCache(Error)
    case readPrebundledRelays(Error)
    case decodePrebundledRelays(Error)
    case writeCache(Error)
    case encodeCache(Error)
    case decodeCache(Error)
    case rest(RestError)

    var errorDescription: String? {
        switch self {
        case .encodeCache:
            return "Encode cache error"
        case .decodeCache:
            return "Decode cache error"
        case .readCache:
            return "Read cache error"
        case .readPrebundledRelays:
            return "Read pre-bundled relays error"
        case .decodePrebundledRelays:
            return "Decode pre-bundled relays error"
        case .writeCache:
            return "Write cache error"
        case .rest:
            return "REST error"
        }
    }
}
