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

    /// Refreshed relays but the same content was found on remote.
    case sameContent

    /// Refreshed relays with new content.
    case newContent
}

class RelayCacheTracker {
    private let logger = Logger(label: "RelayCacheTracker")
    /// The cache location used by the class instance
    private let cacheFileURL: URL

    /// The location of prebundled `relays.json`
    private let prebundledRelaysFileURL: URL

    /// A dispatch queue used for thread synchronization
    private let stateQueue = DispatchQueue(label: "RelayCacheTracker")

    /// A dispatch queue used for serializing downloads
    private let downloadQueue = DispatchQueue(label: "RelayCacheTrackerDownloadQueue")

    /// A timer source used for periodic updates
    private var timerSource: DispatchSourceTimer?

    /// A flag that indicates whether periodic updates are running
    private var isPeriodicUpdatesEnabled = false

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
        stateQueue.async {
            guard !self.isPeriodicUpdatesEnabled else { return }

            self.isPeriodicUpdatesEnabled = true

            switch RelayCacheIO.read(cacheFileURL: self.cacheFileURL) {
            case .success(let cachedRelayList):
                if let nextUpdate = Self.nextUpdateDate(lastUpdatedAt: cachedRelayList.updatedAt) {
                    self.scheduleRepeatingTimer(startTime: .now() + nextUpdate.timeIntervalSinceNow)
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
        stateQueue.async {
            guard self.isPeriodicUpdatesEnabled else { return }

            self.isPeriodicUpdatesEnabled = false

            self.timerSource?.cancel()
            self.timerSource = nil
        }
    }

    func updateRelays() -> Result<RelayFetchResult, RelayCacheError>.Promise {
        return Promise.deferred {
            return RelayCacheIO.read(cacheFileURL: self.cacheFileURL)
        }
        .schedule(on: stateQueue)
        .then { result in
            switch result {
            case .success(let cachedRelays):
                let nextUpdate = Self.nextUpdateDate(lastUpdatedAt: cachedRelays.updatedAt)

                if let nextUpdate = nextUpdate, nextUpdate <= Date() {
                    return self.downloadRelays(previouslyCachedRelays: cachedRelays)
                } else {
                    return .success(.throttled)
                }

            case .failure(let readError):
                self.logger.error(chainedError: readError, message: "Failed to read the relay cache to determine if it needs to be updated")

                if Self.shouldDownloadRelaysOnReadFailure(readError) {
                    return self.downloadRelays(previouslyCachedRelays: nil)
                } else {
                    return .failure(readError)
                }
            }
        }
    }

    func read() -> Result<CachedRelays, RelayCacheError>.Promise {
        return Promise.deferred {
            return RelayCacheIO.readWithFallback(
                cacheFileURL: self.cacheFileURL,
                preBundledRelaysFileURL: self.prebundledRelaysFileURL
            )
        }.schedule(on: stateQueue)
    }

    // MARK: - Observation

    func addObserver<T: RelayCacheObserver>(_ observer: T) {
        observerList.append(AnyRelayCacheObserver(observer))
    }

    func removeObserver<T: RelayCacheObserver>(_ observer: T) {
        observerList.remove(AnyRelayCacheObserver(observer))
    }

    // MARK: - Private instance methods

    private func downloadRelays(previouslyCachedRelays: CachedRelays?) -> Result<RelayFetchResult, RelayCacheError>.Promise {
        return RESTClient.shared.getRelays(etag: previouslyCachedRelays?.etag)
            .receive(on: stateQueue)
            .mapError { error in
                self.logger.error(chainedError: error, message: "Failed to download relays")
                return RelayCacheError.rest(error)
            }
            .mapThen { result in
                switch result {
                case .newContent(let etag, let relays):
                    let numRelays = relays.wireguard.relays.count

                    self.logger.info("Downloaded \(numRelays) relays")

                    let cachedRelays = CachedRelays(etag: etag, relays: relays, updatedAt: Date())

                    return RelayCacheIO.write(cacheFileURL: self.cacheFileURL, record: cachedRelays)
                        .asPromise()
                        .map { _ in
                            self.observerList.forEach { (observer) in
                                observer.relayCache(self, didUpdateCachedRelays: cachedRelays)
                            }

                            return .newContent
                        }
                        .onFailure { error in
                            self.logger.error(chainedError: error, message: "Failed to store downloaded relays")
                        }

                case .notModified:
                    self.logger.info("Relays haven't changed since last check.")

                    var cachedRelays = previouslyCachedRelays!
                    cachedRelays.updatedAt = Date()

                    return RelayCacheIO.write(cacheFileURL: self.cacheFileURL, record: cachedRelays)
                        .asPromise()
                        .map { _ in
                            return .sameContent
                        }
                        .onFailure { error in
                            self.logger.error(chainedError: error, message: "Failed to update cached relays timestamp")
                        }
                }
            }
            .block(on: downloadQueue)
    }

    private func scheduleRepeatingTimer(startTime: DispatchWallTime) {
        let timerSource = DispatchSource.makeTimerSource(queue: stateQueue)
        timerSource.setEventHandler { [weak self] in
            guard let self = self else { return }

            if self.isPeriodicUpdatesEnabled {
                self.updateRelays().observe { _ in }
            }
        }

        timerSource.schedule(wallDeadline: startTime, repeating: .seconds(kUpdateIntervalSeconds))
        timerSource.activate()

        self.timerSource = timerSource
    }

    // MARK: - Private class methods

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
