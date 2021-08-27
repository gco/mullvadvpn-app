//
//  PacketTunnelIPCHandler.swift
//  PacketTunnelIPCHandler
//
//  Created by pronebird on 27/07/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

enum PacketTunnelIpcHandler {}

extension PacketTunnelIpcHandler {

    enum Error: ChainedError {
        /// A failure to encode the request
        case encoding(Swift.Error)

        /// A failure to decode the response
        case decoding(Swift.Error)

        /// A failure to process the request
        case processing(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .encoding:
                return "Encoding failure"
            case .decoding:
                return "Decoding failure"
            case .processing:
                return "Request handling failure"
            }
        }
    }

    static func decodeRequest(messageData: Data) -> Result<PacketTunnelRequest, Error> {
        do {
            let decoder = JSONDecoder()
            let value = try decoder.decode(PacketTunnelRequest.self, from: messageData)

            return .success(value)
        } catch {
            return .failure(.decoding(error))
        }
    }

    static func encodeResponse<T>(_ response: T) -> Result<Data, Error> where T: Codable {
        do {
            let encoder = JSONEncoder()
            let value = try encoder.encode(PacketTunnelResponse(value: response))

            return .success(value)
        } catch {
            return .failure(.encoding(error))
        }
    }
}
