//
//  RESTClient.swift
//  MullvadVPN
//
//  Created by pronebird on 10/07/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import Network
import Security
import WireGuardKit

/// REST API v1 base URL
private let kRestBaseURL = URL(string: "https://api.mullvad.net/app/v1")!

/// Network request timeout in seconds
private let kNetworkTimeout: TimeInterval = 10

/// HTTP method
struct HTTPMethod: RawRepresentable {
    static let get = HTTPMethod(rawValue: "GET")
    static let post = HTTPMethod(rawValue: "POST")
    static let delete = HTTPMethod(rawValue: "DELETE")

    let rawValue: String
    init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }
}

// HTTP status codes
struct HTTPStatus: RawRepresentable, Equatable {
    static let ok = HTTPStatus(rawValue: 200)
    static let created = HTTPStatus(rawValue: 201)
    static let noContent = HTTPStatus(rawValue: 204)
    static let notModified = HTTPStatus(rawValue: 304)

    let rawValue: Int
    init(rawValue value: Int) {
        rawValue = value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.rawValue == rhs.rawValue
    }

    static func == (lhs: Self, rhs: Int) -> Bool {
        return lhs.rawValue == rhs
    }

    static func == (lhs: Int, rhs: Self) -> Bool {
        return lhs == rhs.rawValue
    }

    static func ~= (lhs: Self, rhs: Int) -> Bool {
        return lhs.rawValue == rhs
    }
}

/// HTTP headers
enum HTTPHeader {
    static let authorization = "Authorization"
    static let contentType = "Content-Type"
    static let etag = "ETag"
    static let ifNoneMatch = "If-None-Match"
}

class RESTClient {
    let session: URLSession

    static let shared = RESTClient()

    private let sessionDelegate: SSLPinningURLSessionDelegate

    /// Returns array of trusted root certificates
    private static var trustedRootCertificates: [SecCertificate] {
        let oldRootCertificate = Bundle.main.path(forResource: "old_le_root_cert", ofType: "cer")!
        let newRootCertificate = Bundle.main.path(forResource: "new_le_root_cert", ofType: "cer")!

        return [oldRootCertificate, newRootCertificate].map { (path) -> SecCertificate in
            let data = FileManager.default.contents(atPath: path)!
            return SecCertificateCreateWithData(nil, data as CFData)!
        }
    }

    private init() {
        sessionDelegate = SSLPinningURLSessionDelegate(trustedRootCertificates: Self.trustedRootCertificates)
        session = URLSession(configuration: .ephemeral, delegate: sessionDelegate, delegateQueue: nil)
    }

    // MARK: - Public

    func createAccount() -> Result<AccountResponse, RestError>.Promise {
        let request = makeURLRequest(method: .post, path: "accounts")

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                if httpResponse.statusCode == HTTPStatus.created {
                    return Self.decodeSuccessResponse(AccountResponse.self, from: data)
                } else {
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    func getRelays(etag: String?) -> Result<HttpResourceCacheResponse<ServerRelaysResponse>, RestError>.Promise {
        var request = makeURLRequest(method: .get, path: "relays")
        if let etag = etag {
            setETagHeader(etag: etag, request: &request)
        }

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                switch httpResponse.statusCode {
                case .ok:
                    return Self.decodeSuccessResponse(ServerRelaysResponse.self, from: data)
                        .map { serverRelays in
                            let newEtag = httpResponse.value(forCaseInsensitiveHTTPHeaderField: HTTPHeader.etag)
                            return .newContent(newEtag, serverRelays)
                        }

                case .notModified where etag != nil:
                    return .success(.notModified)

                default:
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    func getAccountExpiry(token: String) -> Result<AccountResponse, RestError>.Promise {
        var request = makeURLRequest(method: .get, path: "me")

        setAuthenticationToken(token: token, request: &request)

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                if httpResponse.statusCode == HTTPStatus.ok {
                    return Self.decodeSuccessResponse(AccountResponse.self, from: data)
                } else {
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    func getWireguardKey(token: String, publicKey: PublicKey) -> Result<WireguardAddressesResponse, RestError>.Promise {
        let urlEncodedPublicKey = publicKey.base64Key
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

        let path = "wireguard-keys/".appending(urlEncodedPublicKey)
        var request = makeURLRequest(method: .get, path: path)

        setAuthenticationToken(token: token, request: &request)

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                if httpResponse.statusCode == HTTPStatus.ok {
                    return Self.decodeSuccessResponse(WireguardAddressesResponse.self, from: data)
                } else {
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    func pushWireguardKey(token: String, publicKey: PublicKey) -> Result<WireguardAddressesResponse, RestError>.Promise {
        var request = makeURLRequest(method: .post, path: "wireguard-keys")
        let body = PushWireguardKeyRequest(pubkey: publicKey.rawValue)

        setAuthenticationToken(token: token, request: &request)

        do {
            try setHTTPBody(value: body, request: &request)
        } catch {
            return .failure(.encodePayload(error))
        }

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                switch httpResponse.statusCode {
                case .created, .ok:
                    return Self.decodeSuccessResponse(WireguardAddressesResponse.self, from: data)
                default:
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    func replaceWireguardKey(token: String, oldPublicKey: PublicKey, newPublicKey: PublicKey) -> Result<WireguardAddressesResponse, RestError>.Promise {
        var request = makeURLRequest(method: .post, path: "replace-wireguard-key")
        let body = ReplaceWireguardKeyRequest(old: oldPublicKey.rawValue, new: newPublicKey.rawValue)

        setAuthenticationToken(token: token, request: &request)

        do {
            try setHTTPBody(value: body, request: &request)
        } catch {
            return .failure(.encodePayload(error))
        }

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                if httpResponse.statusCode == HTTPStatus.created {
                    return Self.decodeSuccessResponse(WireguardAddressesResponse.self, from: data)
                } else {
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    func deleteWireguardKey(token: String, publicKey: PublicKey) -> Result<(), RestError>.Promise {
        let urlEncodedPublicKey = publicKey.base64Key
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

        let path = "wireguard-keys/".appending(urlEncodedPublicKey)
        var request = makeURLRequest(method: .delete, path: path)

        setAuthenticationToken(token: token, request: &request)

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                if httpResponse.statusCode == HTTPStatus.noContent {
                    return .success(())
                } else {
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    func createApplePayment(token: String, receiptString: Data) -> Result<CreateApplePaymentResponse, RestError>.Promise {
        var request = makeURLRequest(method: .post, path: "create-apple-payment")
        let body = CreateApplePaymentRequest(receiptString: receiptString)

        setAuthenticationToken(token: token, request: &request)

        do {
            try setHTTPBody(value: body, request: &request)
        } catch {
            return .failure(.encodePayload(error))
        }

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                switch httpResponse.statusCode {
                case HTTPStatus.ok:
                    return RESTClient.decodeSuccessResponse(CreateApplePaymentRawResponse.self, from: data)
                        .map { (response) in
                            return .noTimeAdded(response.newExpiry)
                        }

                case HTTPStatus.created:
                    return RESTClient.decodeSuccessResponse(CreateApplePaymentRawResponse.self, from: data)
                        .map { (response) in
                            return .timeAdded(response.timeAdded, response.newExpiry)
                        }

                default:
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    func sendProblemReport(_ body: ProblemReportRequest) -> Result<(), RestError>.Promise {
        var request = makeURLRequest(method: .post, path: "problem-report")

        do {
            try setHTTPBody(value: body, request: &request)
        } catch {
            return .failure(.encodePayload(error))
        }

        return dataTaskPromise(request: request)
            .mapError(self.mapNetworkError)
            .flatMap { httpResponse, data in
                if httpResponse.statusCode == HTTPStatus.noContent {
                    return .success(())
                } else {
                    return Self.decodeErrorResponseAndMapToServerError(from: data)
                }
            }
    }

    // MARK: - Private

    /// A private helper that parses the JSON response into the given `Decodable` type.
    fileprivate static func decodeSuccessResponse<T: Decodable>(_ type: T.Type, from data: Data) -> Result<T, RestError> {
        return Result { try RestCoding.makeJSONDecoder().decode(type, from: data) }
            .mapError { error in
                return .decodeSuccessResponse(error)
            }
    }

    /// A private helper that parses the JSON response in case of error (Any HTTP code except 2xx)
    fileprivate static func decodeErrorResponse(from data: Data) -> Result<ServerErrorResponse, RestError> {
        return Result { () -> ServerErrorResponse in
            return try RestCoding.makeJSONDecoder().decode(ServerErrorResponse.self, from: data)
        }.mapError { error in
            return .decodeErrorResponse(error)
        }
    }

    private static func decodeErrorResponseAndMapToServerError<T>(from data: Data) -> Result<T, RestError> {
        return Self.decodeErrorResponse(from: data)
            .flatMap { serverError in
                return .failure(.server(serverError))
            }
    }

    private func mapNetworkError(_ error: URLError) -> RestError {
        return .network(error)
    }

    private func dataTask(request: URLRequest, completion: @escaping (Result<(HTTPURLResponse, Data), URLError>) -> Void) -> URLSessionDataTask {
        return self.session.dataTask(with: request) { data, response, error in
            if let error = error {
                let urlError = error as? URLError ?? URLError(.unknown)

                completion(.failure(urlError))
            } else {
                if let httpResponse = response as? HTTPURLResponse {
                    let data = data ?? Data()
                    let value = (httpResponse, data)

                    completion(.success(value))
                } else {
                    completion(.failure(URLError(.unknown)))
                }
            }
        }
    }

    private func dataTaskPromise(request: URLRequest) -> Result<(HTTPURLResponse, Data), URLError>.Promise {
        return Result<(HTTPURLResponse, Data), URLError>.Promise { resolver in
            let task = self.dataTask(request: request) { result in
                resolver.resolve(value: result)
            }

            resolver.setCancelHandler {
                task.cancel()
            }

            task.resume()
        }
    }

    private func setHTTPBody<T: Encodable>(value: T, request: inout URLRequest) throws {
        request.httpBody = try RestCoding.makeJSONEncoder().encode(value)
    }

    private func setETagHeader(etag: String, request: inout URLRequest) {
        var etag = etag
        // Enforce weak validator to account for some backend caching quirks.
        if etag.starts(with: "\"") {
            etag.insert(contentsOf: "W/", at: etag.startIndex)
        }
        request.setValue(etag, forHTTPHeaderField: HTTPHeader.ifNoneMatch)
    }

    private func setAuthenticationToken(token: String, request: inout URLRequest) {
        request.addValue("Token \(token)", forHTTPHeaderField: HTTPHeader.authorization)
    }

    private func makeURLRequest(method: HTTPMethod, path: String) -> URLRequest {
        var request = URLRequest(
            url: kRestBaseURL.appendingPathComponent(path),
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: kNetworkTimeout
        )
        request.httpShouldHandleCookies = false
        request.addValue("application/json", forHTTPHeaderField: HTTPHeader.contentType)
        request.httpMethod = method.rawValue
        return request
    }
}

// MARK: - Response types

struct AccountResponse: Decodable {
    let token: String
    let expires: Date
}

private extension HTTPURLResponse {
    func value(forCaseInsensitiveHTTPHeaderField headerField: String) -> String? {
        if #available(iOS 13.0, *) {
            return self.value(forHTTPHeaderField: headerField)
        } else {
            for case let key as String in self.allHeaderFields.keys {
                if case .orderedSame = key.caseInsensitiveCompare(headerField) {
                    return self.allHeaderFields[key] as? String
                }
            }
            return nil
        }
    }
}

enum HttpResourceCacheResponse<T: Decodable> {
    case notModified
    case newContent(_ etag: String?, _ value: T)
}

struct PushWireguardKeyRequest: Encodable {
    let pubkey: Data
}

struct WireguardAddressesResponse: Decodable {
    let id: String
    let pubkey: Data
    let ipv4Address: IPAddressRange
    let ipv6Address: IPAddressRange
}

struct ReplaceWireguardKeyRequest: Encodable {
    let old: Data
    let new: Data
}

struct CreateApplePaymentRequest: Encodable {
    let receiptString: Data
}

enum CreateApplePaymentResponse {
    case noTimeAdded(_ expiry: Date)
    case timeAdded(_ timeAdded: Int, _ newExpiry: Date)

    var newExpiry: Date {
        switch self {
        case .noTimeAdded(let expiry), .timeAdded(_, let expiry):
            return expiry
        }
    }

    var timeAdded: TimeInterval {
        switch self {
        case .noTimeAdded:
            return 0
        case .timeAdded(let timeAdded, _):
            return TimeInterval(timeAdded)
        }
    }

    /// Returns a formatted string for the `timeAdded` interval, i.e "30 days"
    var formattedTimeAdded: String? {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour]
        formatter.unitsStyle = .full

        return formatter.string(from: self.timeAdded)
    }
}

fileprivate struct CreateApplePaymentRawResponse: Decodable {
    let timeAdded: Int
    let newExpiry: Date
}

struct ProblemReportRequest: Encodable {
    let address: String
    let message: String
    let log: String
    let metadata: [String: String]
}
