import Foundation
import OpenCastAnalysis

/// Fetches, verifies, clamps and caches the analysis policy bundle, and says
/// which bundle the app runs under.
///
/// The active bundle is a downloaded one only while it verifies against the
/// pinned key, suits this app build, sits inside the clamp, is newer than the
/// baked copy and was confirmed by the server within `maximumCacheAge`.
/// Otherwise the baked copy is active and the snapshot names why. A rejected
/// download never replaces an accepted one, and the loader never accepts a
/// lower version than it already has.
///
/// A refresh reads the current signature first, then the immutable bundle of
/// the version it names, and verifies the signature over those bytes, so it
/// can never pair a signature with another generation's bundle. When the
/// signature still names the accepted bundle only the signature is fetched.
///
/// Call `refreshIfDue()` at launch: it fetches when the last success is a day
/// old, or an hour after a failure.
public actor AnalysisPolicyLoader {
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    public static let failureRetryInterval: TimeInterval = 60 * 60
    /// A downloaded bundle the server has not re-served for this long is no
    /// longer trusted over the baked copy.
    public static let maximumCacheAge: TimeInterval = 30 * 24 * 60 * 60

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "AnalysisPolicy", directoryHint: .isDirectory)
    }

    private let endpoint: AnalysisPolicyEndpoint
    private let fetcher: any AnalysisPolicyFetching
    private let validator: AnalysisPolicyValidator
    private let store: AnalysisPolicyStore
    private let baked: AnalysisPolicyBundle
    private let now: @Sendable () -> Date

    private var loaded = false
    private var cached: (bundle: AnalysisPolicyBundle, data: Data, confirmedAt: Date)?
    private var cacheRejection: AnalysisPolicyRejection?
    private var metadata = AnalysisPolicyStore.Metadata()
    private var refreshTask: Task<Void, Never>?

    public init(
        appBuild: Int,
        directory: URL = AnalysisPolicyLoader.defaultDirectory,
        endpoint: AnalysisPolicyEndpoint,
        fetcher: any AnalysisPolicyFetching = URLSessionAnalysisPolicyFetcher(),
        verifier: AnalysisPolicySignatureVerifier = .pinned,
        baked: AnalysisPolicyBundle = .baked,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.endpoint = endpoint
        self.fetcher = fetcher
        validator = AnalysisPolicyValidator(verifier: verifier, appBuild: appBuild)
        store = AnalysisPolicyStore(directory: directory)
        self.baked = baked
        self.now = now
    }

    /// The bundle to run under now.
    public func snapshot() -> AnalysisPolicySnapshot {
        loadIfNeeded()
        let lastFailure = metadata.lastFailure
        let fallbackReason: AnalysisPolicyRejection?
        if let cached {
            guard cached.bundle.bundleVersion > baked.bundleVersion else {
                return AnalysisPolicySnapshot(bundle: baked, source: .baked, fallbackReason: nil, lastRefreshFailure: lastFailure)
            }
            let confirmedAt = cached.confirmedAt
            let age = now().timeIntervalSince(confirmedAt)
            if age <= Self.maximumCacheAge {
                return AnalysisPolicySnapshot(
                    bundle: cached.bundle,
                    source: .downloaded(confirmedAt: confirmedAt),
                    fallbackReason: nil,
                    lastRefreshFailure: lastFailure
                )
            }
            fallbackReason = .cacheStale(days: Int(age / (24 * 60 * 60)))
        } else {
            fallbackReason = cacheRejection ?? lastFailure
        }
        return AnalysisPolicySnapshot(bundle: baked, source: .baked, fallbackReason: fallbackReason, lastRefreshFailure: lastFailure)
    }

    /// Whether a refresh would fetch now.
    public func isRefreshDue() -> Bool {
        loadIfNeeded()
        guard let lastAttempt = metadata.lastAttemptAt else { return true }
        let elapsed = now().timeIntervalSince(lastAttempt)
        guard elapsed >= 0 else { return true }
        return elapsed >= (metadata.lastFailure == nil ? Self.refreshInterval : Self.failureRetryInterval)
    }

    /// Fetches when due, then returns the snapshot.
    public func refreshIfDue() async -> AnalysisPolicySnapshot {
        if isRefreshDue() {
            return await refresh()
        }
        return snapshot()
    }

    /// Fetches now. Concurrent callers share one fetch.
    public func refresh() async -> AnalysisPolicySnapshot {
        loadIfNeeded()
        if let refreshTask {
            await refreshTask.value
            return snapshot()
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
        return snapshot()
    }

    private func performRefresh() async {
        let attemptAt = now()
        metadata.lastAttemptAt = attemptAt
        do {
            let signatureData = try await download(
                endpoint.signatureURL,
                maximumBytes: AnalysisPolicyValidator.maximumSignatureBytes
            )
            let binding = try AnalysisPolicySignatureVerifier.binding(in: signatureData)
            let accepted = max(metadata.highestAcceptedVersion, cached?.bundle.bundleVersion ?? 0)
            guard binding.bundleVersion >= accepted else {
                throw AnalysisPolicyRejection.rollback(accepted: accepted, offered: binding.bundleVersion)
            }
            let bundleData: Data
            if let cached, cached.bundle.bundleVersion == binding.bundleVersion {
                // Same version: the validator below proves the new signature
                // covers the bytes already held, so nothing else is fetched.
                bundleData = cached.data
            } else {
                bundleData = try await download(
                    endpoint.bundleURL(version: binding.bundleVersion),
                    maximumBytes: AnalysisPolicyValidator.maximumBundleBytes
                )
            }
            let bundle = try validator.validate(bundleData: bundleData, signatureData: signatureData)
            cached = (bundle, bundleData, attemptAt)
            cacheRejection = nil
            do {
                try store.writeCachedBundle(.init(bundle: bundleData, signature: signatureData, confirmedAt: attemptAt))
                // The high-water mark only moves once the bundle it names is
                // on disk, so a relaunch can never find a lower cache under it.
                metadata.highestAcceptedVersion = max(accepted, bundle.bundleVersion)
                metadata.lastFailure = nil
            } catch {
                // Active for this session; retried on the failure cadence.
                metadata.lastFailure = .persistenceFailed
            }
        } catch let rejection as AnalysisPolicyRejection {
            metadata.lastFailure = rejection
        } catch {
            metadata.lastFailure = .fetchFailed(Self.describe(error))
        }
        try? store.writeMetadata(metadata)
    }

    private func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        try await fetcher.fetch(url, maximumBytes: maximumBytes)
    }

    /// Reads the cache once per process and re-verifies it as if downloaded.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        metadata = store.readMetadata()
        guard let stored = store.readCachedBundle() else { return }
        do throws(AnalysisPolicyRejection) {
            let bundle = try validator.validate(bundleData: stored.bundle, signatureData: stored.signature)
            guard bundle.bundleVersion >= metadata.highestAcceptedVersion else {
                throw .rollback(
                    accepted: metadata.highestAcceptedVersion,
                    offered: bundle.bundleVersion
                )
            }
            cached = (bundle, stored.bundle, stored.confirmedAt)
        } catch {
            cacheRejection = error
        }
    }

    /// Content-free: a URL error code or the error's type, never a body.
    private static func describe(_ error: any Error) -> String {
        if let error = error as? URLError {
            return "url_error_\(error.code.rawValue)"
        }
        if error is CancellationError {
            return "cancelled"
        }
        return String(describing: type(of: error))
    }
}
