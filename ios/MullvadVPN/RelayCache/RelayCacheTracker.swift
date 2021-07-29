//
//  RelayCacheTracker.swift
//  MullvadVPN
//
//  Created by pronebird on 05/06/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import Logging

/// Periodic update interval
private let kUpdateIntervalSeconds = 3600

protocol RelayCacheObserver: AnyObject {
    func relayCache(_ relayCache: RelayCacheTracker, didUpdateCachedRelays cachedRelays: CachedRelays)
}

private class AnyRelayCacheObserver: WeakObserverBox, RelayCacheObserver {

    typealias Wrapped = RelayCacheObserver

    private(set) weak var inner: RelayCacheObserver?

    init<T: RelayCacheObserver>(_ inner: T) {
        self.inner = inner
    }

    func relayCache(_ relayCache: RelayCacheTracker, didUpdateCachedRelays cachedRelays: CachedRelays) {
        inner?.relayCache(relayCache, didUpdateCachedRelays: cachedRelays)
    }

    static func == (lhs: AnyRelayCacheObserver, rhs: AnyRelayCacheObserver) -> Bool {
        return lhs.inner === rhs.inner
    }
}

enum RelayFetchResult {
    /// Request to update relays was throttled.
    case throttled

    /// Failure to download relays.
    case failure(Error)

    /// Refreshed relays but the same content was found on remote.
    case sameContent

    /// Refreshed relays with new content.
    case newContent
}

class RelayCacheTracker {
    private let logger = Logger(label: "RelayCache")

    /// Mullvad REST client
    private let rest = MullvadRest()

    /// The cache location used by the class instance
    private let cacheFileURL: URL

    /// The location of prebundled `relays.json`
    private let prebundledRelaysFileURL: URL

    /// A dispatch queue used for thread synchronization
    private let dispatchQueue = DispatchQueue(label: "RelayCacheTracker")

    /// A timer source used for periodic updates
    private var timerSource: DispatchSourceTimer?

    /// A flag that indicates whether periodic updates are running
    private var isPeriodicUpdatesEnabled = false

    /// A download task used for relay RPC request
    private var downloadTask: URLSessionTask?

    /// Observers
    private let observerList = ObserverList<AnyRelayCacheObserver>()

    /// A shared instance of `RelayCache`
    static let shared: RelayCacheTracker = {
        let cacheFileURL = RelayCacheIO.defaultCacheFileURL(forSecurityApplicationGroupIdentifier: ApplicationConfiguration.securityGroupIdentifier)!
        let prebundledRelaysFileURL = RelayCacheIO.preBundledRelaysFileURL!

        return RelayCacheTracker(
            cacheFileURL: cacheFileURL,
            prebundledRelaysFileURL: prebundledRelaysFileURL
        )
    }()

    private init(cacheFileURL: URL, prebundledRelaysFileURL: URL) {
        self.cacheFileURL = cacheFileURL
        self.prebundledRelaysFileURL = prebundledRelaysFileURL
    }

    func startPeriodicUpdates() {
        dispatchQueue.async {
            guard !self.isPeriodicUpdatesEnabled else { return }

            self.isPeriodicUpdatesEnabled = true

            switch RelayCacheIO.read(cacheFileURL: self.cacheFileURL) {
            case .success(let cachedRelayList):
                if let nextUpdate = Self.nextUpdateDate(lastUpdatedAt: cachedRelayList.updatedAt) {
                    let startTime = Self.makeWalltime(fromDate: nextUpdate)
                    self.scheduleRepeatingTimer(startTime: startTime)
                }

            case .failure(let readError):
                self.logger.error(chainedError: readError, message: "Failed to read the relay cache")

                if Self.shouldDownloadRelaysOnReadFailure(readError) {
                    self.scheduleRepeatingTimer(startTime: .now())
                }
            }
        }
    }

    func stopPeriodicUpdates() {
        dispatchQueue.async {
            guard self.isPeriodicUpdatesEnabled else { return }

            self.isPeriodicUpdatesEnabled = false

            self.timerSource?.cancel()
            self.timerSource = nil

            self.downloadTask?.cancel()
            self.downloadTask = nil
        }
    }

    func updateRelays(completionHandler: ((RelayFetchResult) -> Void)?) {
        dispatchQueue.async {
            self._updateRelays(completionHandler: completionHandler)
        }
    }

    /// Read the relay cache from disk.
    func read(completionHandler: @escaping (Result<CachedRelays, RelayCacheError>) -> Void) {
        dispatchQueue.async {
            let result = RelayCacheIO.readWithFallback(
                cacheFileURL: self.cacheFileURL,
                preBundledRelaysFileURL: self.prebundledRelaysFileURL
            )
            completionHandler(result)
        }
    }

    // MARK: - Observation

    func addObserver<T: RelayCacheObserver>(_ observer: T) {
        observerList.append(AnyRelayCacheObserver(observer))
    }

    func removeObserver<T: RelayCacheObserver>(_ observer: T) {
        observerList.remove(AnyRelayCacheObserver(observer))
    }

    // MARK: - Private instance methods

    private func _updateRelays(completionHandler: ((RelayFetchResult) -> Void)?) {
        switch RelayCacheIO.read(cacheFileURL: self.cacheFileURL) {
        case .success(let cachedRelays):
            let nextUpdate = Self.nextUpdateDate(lastUpdatedAt: cachedRelays.updatedAt)

            if let nextUpdate = nextUpdate, nextUpdate <= Date() {
                self.downloadRelays(previouslyCachedRelays: cachedRelays, completionHandler: completionHandler)
            } else {
                completionHandler?(.throttled)
            }

        case .failure(let readError):
            self.logger.error(chainedError: readError, message: "Failed to read the relay cache to determine if it needs to be updated")

            if Self.shouldDownloadRelaysOnReadFailure(readError) {
                self.downloadRelays(previouslyCachedRelays: nil, completionHandler: completionHandler)
            } else {
                completionHandler?(.failure(readError))
            }
        }
    }

    private func downloadRelays(previouslyCachedRelays: CachedRelays?, completionHandler: ((RelayFetchResult) -> Void)?) {
        let taskResult = makeDownloadTask(etag: previouslyCachedRelays?.etag) { (result) in
            switch result {
            case .success(.newContent(let etag, let relays)):
                let numRelays = relays.wireguard.relays.count

                self.logger.info("Downloaded \(numRelays) relays")

                let cachedRelays = CachedRelays(etag: etag, relays: relays, updatedAt: Date())
                switch RelayCacheIO.write(cacheFileURL: self.cacheFileURL, record: cachedRelays) {
                case .success:
                    self.observerList.forEach { (observer) in
                        observer.relayCache(self, didUpdateCachedRelays: cachedRelays)
                    }

                    completionHandler?(.newContent)

                case .failure(let error):
                    self.logger.error(chainedError: error, message: "Failed to store downloaded relays")
                    completionHandler?(.failure(error))
                }

            case .success(.notModified):
                self.logger.info("Relays haven't changed since last check.")

                var cachedRelays = previouslyCachedRelays!
                cachedRelays.updatedAt = Date()

                switch RelayCacheIO.write(cacheFileURL: self.cacheFileURL, record: cachedRelays) {
                case .success:
                    completionHandler?(.sameContent)

                case .failure(let error):
                    self.logger.error(chainedError: error, message: "Failed to update cached relays timestamp")
                    completionHandler?(.failure(error))
                }

            case .failure(let error):
                self.logger.error(chainedError: error, message: "Failed to download relays")
                completionHandler?(.failure(error))
            }
        }

        downloadTask?.cancel()

        switch taskResult {
        case .success(let newDownloadTask):
            downloadTask = newDownloadTask
            newDownloadTask.resume()

        case .failure(let restError):
            self.logger.error(chainedError: restError, message: "Failed to create a REST request for updating relays")
            downloadTask = nil
            completionHandler?(.failure(restError))
        }
    }

    private func scheduleRepeatingTimer(startTime: DispatchWallTime) {
        let timerSource = DispatchSource.makeTimerSource(queue: dispatchQueue)
        timerSource.setEventHandler { [weak self] in
            guard let self = self else { return }

            if self.isPeriodicUpdatesEnabled {
                self._updateRelays(completionHandler: nil)
            }
        }

        timerSource.schedule(wallDeadline: startTime, repeating: .seconds(kUpdateIntervalSeconds))
        timerSource.activate()

        self.timerSource = timerSource
    }

    private func makeDownloadTask(etag: String?, completionHandler: @escaping (Result<HttpResourceCacheResponse<ServerRelaysResponse>, RelayCacheError>) -> Void) -> Result<URLSessionDataTask, RestError> {
        return rest.getRelays().dataTask(payload: ETagPayload(etag: etag, enforceWeakValidator: true, payload: EmptyPayload())) { (result) in
            self.dispatchQueue.async {
                completionHandler(result.mapError { RelayCacheError.rest($0) })
            }
        }
    }

    // MARK: - Private class methods

    private class func makeWalltime(fromDate date: Date) -> DispatchWallTime {
        let (seconds, frac) = modf(date.timeIntervalSince1970)

        let nsec: Double = frac * Double(NSEC_PER_SEC)
        let walltime = timespec(tv_sec: Int(seconds), tv_nsec: Int(nsec))

        return DispatchWallTime(timespec: walltime)
    }

    private class func nextUpdateDate(lastUpdatedAt: Date) -> Date? {
        return Calendar.current.date(
            byAdding: .second,
            value: kUpdateIntervalSeconds,
            to: lastUpdatedAt
        )
    }

    private class func shouldDownloadRelaysOnReadFailure(_ error: RelayCacheError) -> Bool {
        switch error {
        case .readPrebundledRelays, .decodePrebundledRelays, .decodeCache:
            return true

        case .readCache(CocoaError.fileReadNoSuchFile):
            return true

        default:
            return false
        }
    }
}
