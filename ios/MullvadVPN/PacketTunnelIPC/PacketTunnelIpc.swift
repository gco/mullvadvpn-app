//
//  PacketTunnelIpc.swift
//  MullvadVPN
//
//  Created by pronebird on 01/11/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import NetworkExtension

class PacketTunnelIpc {

    enum Error: ChainedError {
        /// A failure to encode the request
        case encoding(Swift.Error)

        /// A failure to decode the response
        case decoding(Swift.Error)

        /// A failure to send the IPC request
        case send(Swift.Error)

        /// A failure that's raised when the IPC response does not contain any data however the decoder
        /// expected to receive data for decoding
        case nilResponse

        var errorDescription: String? {
            switch self {
            case .encoding:
                return "Encoding failure"
            case .decoding:
                return "Decoding failure"
            case .send:
                return "Submission failure"
            case .nilResponse:
                return "Unexpected nil response from the tunnel"
            }
        }
    }

    let session: VPNTunnelProviderSessionProtocol

    init(session: VPNTunnelProviderSessionProtocol) {
        self.session = session
    }

    func reloadTunnelSettings() -> Result<(), Error>.Promise {
        return Result<(), Error>.Promise { resolver in
            self.send(message: .reloadTunnelSettings) { result in
                resolver.resolve(value: result)
            }
        }
    }

    func getTunnelConnectionInfo() -> Result<TunnelConnectionInfo?, Error>.Promise {
        return Result<TunnelConnectionInfo?, Error>.Promise { resolver in
            self.send(message: .tunnelConnectionInfo) { result in
                resolver.resolve(value: result)
            }
        }
    }

    private class func encodeRequest(message: PacketTunnelRequest) -> Result<Data, Error> {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)

            return .success(data)
        } catch {
            return .failure(.encoding(error))
        }
    }

    private class func decodeResponse<T>(data: Data) -> Result<T, Error> where T: Codable {
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(PacketTunnelResponse<T>.self, from: data)

            return .success(response.value)
        } catch {
            return .failure(.decoding(error))
        }
    }

    private func send(message: PacketTunnelRequest, completionHandler: @escaping (Result<(), Error>) -> Void) {
        sendWithoutDecoding(message: message) { (result) in
            let result = result.map { _ in () }

            completionHandler(result)
        }
    }

    private func send<T>(message: PacketTunnelRequest, completionHandler: @escaping (Result<T, Error>) -> Void)
        where T: Codable
    {
        sendWithoutDecoding(message: message) { (result) in
            let result = result.flatMap { (data) -> Result<T, Error> in
                if let data = data {
                    return Self.decodeResponse(data: data)
                } else {
                    return .failure(.nilResponse)
                }
            }

            completionHandler(result)
        }
    }

    private func sendWithoutDecoding(message: PacketTunnelRequest, completionHandler: @escaping (Result<Data?, Error>) -> Void) {
        switch Self.encodeRequest(message: message) {
        case .success(let data):
            self.sendProviderMessage(data) { (result) in
                completionHandler(result)
            }

        case .failure(let error):
            completionHandler(.failure(error))
        }
    }

    private func sendProviderMessage(_ messageData: Data, completionHandler: @escaping (Result<Data?, Error>) -> Void) {
        do {
            try self.session.sendProviderMessage(messageData, responseHandler: { (response) in
                completionHandler(.success(response))
            })
        } catch {
            completionHandler(.failure(.send(error)))
        }
    }

}
