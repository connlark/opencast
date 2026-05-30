import Foundation
import Observation
import OpenCastCore

@Observable
final class OpenCastCacheController {
    private typealias CacheSummaries = (
        feed: CacheStorageSummary,
        artwork: CacheStorageSummary
    )

    nonisolated static let rootDirectoryName = "OpenCast"
    nonisolated static let feedCacheDirectoryName = "FeedCache"
    nonisolated static let artworkCacheDirectoryName = "ArtworkCache"
    nonisolated static let feedCacheBudget: Int64 = 128 * 1_024 * 1_024
    nonisolated static let artworkCacheBudget: Int64 = 256 * 1_024 * 1_024

    private(set) var feedCacheSummary = CacheStorageSummary.empty
    private(set) var artworkCacheSummary = CacheStorageSummary.empty
    private(set) var lastErrorMessage: String?

    let rootDirectory: URL
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceGeneration = 0

    init(rootDirectory: URL = OpenCastCacheController.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        prepareDirectories()
        refreshSummaries()
    }

    var feedCacheDirectory: URL {
        rootDirectory.appending(path: Self.feedCacheDirectoryName, directoryHint: .isDirectory)
    }

    var artworkCacheDirectory: URL {
        rootDirectory.appending(path: Self.artworkCacheDirectoryName, directoryHint: .isDirectory)
    }

    var httpCacheDirectory: URL {
        feedCacheDirectory.appending(path: "HTTPURLCache", directoryHint: .isDirectory)
    }

    var diagnostics: [String: String] {
        [
            "Root": rootDirectory.path,
            "Feed Cache": feedCacheSummary.formattedByteCount,
            "Artwork Cache": artworkCacheSummary.formattedByteCount,
            "HTTP User Agent": OpenCastURLSessionFactory.userAgent
        ]
    }

    nonisolated static func defaultRootDirectory() -> URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDirectory.appending(path: rootDirectoryName, directoryHint: .isDirectory)
    }

    nonisolated static func defaultArtworkCacheDirectory() -> URL {
        defaultRootDirectory().appending(path: artworkCacheDirectoryName, directoryHint: .isDirectory)
    }

    nonisolated static func defaultHTTPCacheDirectory() -> URL {
        defaultRootDirectory()
            .appending(path: feedCacheDirectoryName, directoryHint: .isDirectory)
            .appending(path: "HTTPURLCache", directoryHint: .isDirectory)
    }

    func refreshSummaries() {
        let feedCacheDirectory = feedCacheDirectory
        let artworkCacheDirectory = artworkCacheDirectory

        scheduleMaintenance {
            try await Self.cacheSummaries(
                feedCacheDirectory: feedCacheDirectory,
                artworkCacheDirectory: artworkCacheDirectory
            )
        }
    }

    func clearCaches() {
        let feedCacheDirectory = feedCacheDirectory
        let artworkCacheDirectory = artworkCacheDirectory

        scheduleMaintenance {
            try await Self.removeDirectoryContents(feedCacheDirectory)
            try await Self.removeDirectoryContents(artworkCacheDirectory)
            return try await Self.cacheSummaries(
                feedCacheDirectory: feedCacheDirectory,
                artworkCacheDirectory: artworkCacheDirectory
            )
        }
    }

    func pruneIfNeeded() {
        let feedCacheDirectory = feedCacheDirectory
        let artworkCacheDirectory = artworkCacheDirectory

        scheduleMaintenance {
            try await Self.prune(directory: feedCacheDirectory, byteBudget: Self.feedCacheBudget)
            try await Self.prune(directory: artworkCacheDirectory, byteBudget: Self.artworkCacheBudget)
            return try await Self.cacheSummaries(
                feedCacheDirectory: feedCacheDirectory,
                artworkCacheDirectory: artworkCacheDirectory
            )
        }
    }

    func waitForPendingMaintenance() async {
        await maintenanceTask?.value
    }

    private func prepareDirectories() {
        do {
            try Self.ensureCacheDirectory(rootDirectory)
            try Self.ensureCacheDirectory(feedCacheDirectory)
            try Self.ensureCacheDirectory(artworkCacheDirectory)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func scheduleMaintenance(
        _ operation: @escaping @Sendable () async throws -> CacheSummaries
    ) {
        maintenanceGeneration += 1
        let generation = maintenanceGeneration
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            do {
                let summaries = try await operation()
                try Task.checkCancellation()
                guard let self, self.maintenanceGeneration == generation else {
                    return
                }
                apply(summaries)
                lastErrorMessage = nil
                maintenanceTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.maintenanceGeneration == generation else {
                    return
                }
                lastErrorMessage = error.localizedDescription
                maintenanceTask = nil
            }
        }
    }

    private func apply(_ summaries: CacheSummaries) {
        feedCacheSummary = summaries.feed
        artworkCacheSummary = summaries.artwork
    }

    private nonisolated static func ensureCacheDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(resourceValues)
    }

    @concurrent
    private static func cacheSummaries(
        feedCacheDirectory: URL,
        artworkCacheDirectory: URL
    ) async throws -> CacheSummaries {
        async let feedSummary = summary(for: feedCacheDirectory)
        async let artworkSummary = summary(for: artworkCacheDirectory)
        return try await (feedSummary, artworkSummary)
    }

    @concurrent
    private static func summary(for directory: URL) async throws -> CacheStorageSummary {
        var byteCount: Int64 = 0
        var fileCount = 0
        for fileURL in try recursiveFiles(in: directory) {
            byteCount += try fileSize(at: fileURL)
            fileCount += 1
        }
        return CacheStorageSummary(byteCount: byteCount, fileCount: fileCount)
    }

    @concurrent
    private static func removeDirectoryContents(_ directory: URL) async throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            try FileManager.default.removeItem(at: url)
        }
    }

    @concurrent
    private static func prune(directory: URL, byteBudget: Int64) async throws {
        let files = try recursiveFiles(in: directory).map { url in
            CacheFileCandidate(
                url: url,
                byteCount: try fileSize(at: url),
                lastAccess: lastAccessDate(for: url)
            )
        }
        var totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
        guard totalBytes > byteBudget else {
            return
        }

        for file in files.sorted(by: { $0.lastAccess < $1.lastAccess }) {
            try FileManager.default.removeItem(at: file.url)
            totalBytes -= file.byteCount
            if totalBytes <= byteBudget {
                break
            }
        }
    }

    private nonisolated static func recursiveFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                return nil
            }
            return url
        }
    }

    private nonisolated static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private nonisolated static func lastAccessDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
    }
}
