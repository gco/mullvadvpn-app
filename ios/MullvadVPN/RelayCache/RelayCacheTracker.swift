//
//  RelayCacheTracker.swift
//  MullvadVPN
//
//  Created by pronebird on 05/06/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import BackgroundTasks
import Foundation
import Logging

extension RelayCache {

    enum FetchResult: CustomStringConvertible {
        /// Request to update relays was throttled.
        case throttled

        /// Refreshed relays but the same content was found on remote.
        case sameContent

        /// Refreshed relays with new content.
        case newContent

        var description: String {
            switch self {
            case .throttled:
                return "throttled"
            case .sameContent:
                return "same content"
            case .newContent:
                return "new content"
            }
        }
    }

    class Tracker {
        /// Relay update interval (in seconds)
        private static let relayUpdateInterval: TimeInterval = 60 * 60

        /// Tracker log
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
        static let shared: RelayCache.Tracker = {
            let cacheFileURL = RelayCache.IO.defaultCacheFileURL(forSecurityApplicationGroupIdentifier: ApplicationConfiguration.securityGroupIdentifier)!
            let prebundledRelaysFileURL = RelayCache.IO.preBundledRelaysFileURL!

            return Tracker(
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

                switch RelayCache.IO.read(cacheFileURL: self.cacheFileURL) {
                case .success(let cachedRelays):
                    let nextUpdate = cachedRelays.updatedAt.addingTimeInterval(Self.relayUpdateInterval)
                    self.scheduleRepeatingTimer(startTime: .now() + nextUpdate.timeIntervalSinceNow)

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

        func updateRelays() -> Result<RelayCache.FetchResult, RelayCache.Error>.Promise {
            return Promise.deferred {
                return RelayCache.IO.read(cacheFileURL: self.cacheFileURL)
            }
            .schedule(on: stateQueue)
            .then { result in
                switch result {
                case .success(let cachedRelays):
                    let nextUpdate = cachedRelays.updatedAt.addingTimeInterval(Self.relayUpdateInterval)

                    if nextUpdate <= Date() {
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

        func read() -> Result<CachedRelays, RelayCache.Error>.Promise {
            return Promise.deferred {
                return RelayCache.IO.readWithFallback(
                    cacheFileURL: self.cacheFileURL,
                    preBundledRelaysFileURL: self.prebundledRelaysFileURL
                )
            }.schedule(on: stateQueue)
        }

        // MARK: - Background tasks

        /// Register app refresh task with scheduler.
        @available(iOS 13.0, *)
        func registerAppRefreshTask() {
            let taskIdentifier = ApplicationConfiguration.appRefreshTaskIdentifier

            let isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
                var cancellationToken: PromiseCancellationToken?

                self.logger.debug("Start app refresh task")

                self.updateRelays()
                    .storeCancellationToken(in: &cancellationToken)
                    .observe { completion in
                        // Schedule next refresh
                        let nextDate = Date().addingTimeInterval(Self.relayUpdateInterval)

                        switch self.submitAppRefreshTask(at: nextDate) {
                        case .success:
                            self.logger.debug("Scheduled next app refresh task at \(nextDate)")
                        case .failure(let error):
                            self.logger.error(chainedError: error, message: "Failed to schedule next app refresh task")
                        }

                        // Complete current task
                        task.setTaskCompleted(success: !completion.isCancelled)
                    }

                task.expirationHandler = {
                    cancellationToken?.cancel()
                }
            }

            if isRegistered {
                logger.debug("Registered app refresh task: \(taskIdentifier)")
            } else {
                logger.error("Failed to register app refresh task: \(taskIdentifier)")
            }
        }

        /// Schedules app refresh task relative to the last relays update.
        @available(iOS 13.0, *)
        func scheduleAppRefreshTask() -> Result<(), RelayCache.Error>.Promise {
            return self.read().flatMap { cachedRelays in
                let beginDate = cachedRelays.updatedAt.addingTimeInterval(Self.relayUpdateInterval)

                return self.submitAppRefreshTask(at: beginDate)
            }
        }

        /// Create and submit task request to scheduler.
        @available(iOS 13.0, *)
        private func submitAppRefreshTask(at beginDate: Date) -> Result<(), RelayCache.Error> {
            let request = BGAppRefreshTaskRequest(identifier: ApplicationConfiguration.appRefreshTaskIdentifier)
            request.earliestBeginDate = beginDate

            return Result { try BGTaskScheduler.shared.submit(request) }
                .mapError { error in
                    return .backgroundTaskScheduler(error)
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

        private func downloadRelays(previouslyCachedRelays: CachedRelays?) -> Result<RelayCache.FetchResult, RelayCache.Error>.Promise {
            return REST.Client.shared.getRelays(etag: previouslyCachedRelays?.etag)
                .receive(on: stateQueue)
                .mapError { error in
                    self.logger.error(chainedError: error, message: "Failed to download relays")
                    return RelayCache.Error.rest(error)
                }
                .mapThen { result in
                    switch result {
                    case .newContent(let etag, let relays):
                        let numRelays = relays.wireguard.relays.count

                        self.logger.info("Downloaded \(numRelays) relays")

                        let cachedRelays = CachedRelays(etag: etag, relays: relays, updatedAt: Date())

                        return RelayCache.IO.write(cacheFileURL: self.cacheFileURL, record: cachedRelays)
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

                        return RelayCache.IO.write(cacheFileURL: self.cacheFileURL, record: cachedRelays)
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
                self?.updateRelays().observe { _ in }
            }

            timerSource.schedule(wallDeadline: startTime, repeating: .seconds(Int(Self.relayUpdateInterval)))
            timerSource.activate()

            self.timerSource = timerSource
        }

        // MARK: - Private class methods

        private class func shouldDownloadRelaysOnReadFailure(_ error: RelayCache.Error) -> Bool {
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

}
