import CryptoKit
import Foundation

actor StreamingAudioDiskCache {
    private static let lastAccessWriteInterval: TimeInterval = 30
    private static let scheduledPruneDelay: Duration = .seconds(2)

    private let directory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var scheduledPruneTask: Task<Void, Never>?

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func cachedData(
        episodeID: String,
        originalURL: URL,
        range: Range<Int64>,
        now: Date = .now
    ) throws -> Data? {
        try cachedResponse(
            episodeID: episodeID,
            originalURL: originalURL,
            range: range,
            now: now
        )?.data
    }

    func cachedResponse(
        episodeID: String,
        originalURL: URL,
        range: Range<Int64>,
        now: Date = .now
    ) throws -> StreamingAudioCachedResponse? {
        try prepareDirectory()
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound else {
            throw StreamingAudioCacheError.invalidRange
        }

        let entryDirectory = entryDirectory(episodeID: episodeID, originalURL: originalURL)
        let manifestURL = manifestURL(in: entryDirectory)
        let dataURL = dataURL(in: entryDirectory)
        guard fileManager.fileExists(atPath: manifestURL.path),
              fileManager.fileExists(atPath: dataURL.path)
        else {
            return nil
        }

        var manifest = try readManifest(at: manifestURL)
        guard manifest.contains(range) else {
            return nil
        }

        if now.timeIntervalSince(manifest.lastAccess) >= Self.lastAccessWriteInterval {
            manifest.lastAccess = now
            try writeManifest(manifest, to: manifestURL)
        }

        let handle = try FileHandle(forReadingFrom: dataURL)
        defer {
            try? handle.close()
        }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        guard let data = try handle.read(upToCount: Int(range.upperBound - range.lowerBound)),
              Int64(data.count) == range.upperBound - range.lowerBound
        else {
            return nil
        }
        return StreamingAudioCachedResponse(
            data: data,
            contentLength: manifest.contentLength,
            mimeType: manifest.mimeType
        )
    }

    @discardableResult
    func store(
        _ response: StreamingAudioRangeResponse,
        episodeID: String,
        podcastID: String?,
        originalURL: URL,
        now: Date = .now
    ) throws -> StreamingAudioCacheManifest {
        try prepareDirectory()
        guard response.range.lowerBound >= 0,
              response.range.upperBound > response.range.lowerBound,
              Int64(response.data.count) == response.range.upperBound - response.range.lowerBound
        else {
            throw StreamingAudioCacheError.invalidRange
        }
        guard response.metadata.acceptsRanges else {
            throw StreamingAudioCacheError.noRangeSupport
        }
        guard response.metadata.hasValidator else {
            throw StreamingAudioCacheError.missingValidator
        }

        let entryDirectory = entryDirectory(episodeID: episodeID, originalURL: originalURL)
        try fileManager.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
        let manifestURL = manifestURL(in: entryDirectory)
        let dataURL = dataURL(in: entryDirectory)
        var manifest = try existingManifest(at: manifestURL) ?? StreamingAudioCacheManifest(
            episodeID: episodeID,
            podcastID: podcastID,
            originalURL: originalURL.absoluteString,
            contentLength: response.metadata.contentLength,
            mimeType: response.metadata.mimeType,
            etag: response.metadata.etag,
            lastModified: response.metadata.lastModified,
            acceptsRanges: response.metadata.acceptsRanges,
            byteRanges: [],
            lastAccess: now,
            lastValidation: now,
            validationState: .valid,
            isCompleted: false
        )

        try validate(response.metadata, against: manifest)
        try write(response.data, to: dataURL, at: response.range.lowerBound)

        manifest.podcastID = manifest.podcastID ?? podcastID
        manifest.contentLength = response.metadata.contentLength ?? manifest.contentLength
        manifest.mimeType = response.metadata.mimeType ?? manifest.mimeType
        manifest.etag = response.metadata.etag ?? manifest.etag
        manifest.lastModified = response.metadata.lastModified ?? manifest.lastModified
        manifest.acceptsRanges = response.metadata.acceptsRanges
        manifest.lastAccess = now
        manifest.lastValidation = now
        manifest.validationState = .valid
        manifest.merge(response.range)
        if let contentLength = manifest.contentLength,
           manifest.contains(0..<contentLength) {
            manifest.isCompleted = true
        }
        try writeManifest(manifest, to: manifestURL)
        return manifest
    }

    func manifest(episodeID: String, originalURL: URL) throws -> StreamingAudioCacheManifest? {
        try prepareDirectory()
        return try existingManifest(at: manifestURL(in: entryDirectory(episodeID: episodeID, originalURL: originalURL)))
    }

    func markCompleted(episodeID: String, originalURL: URL) throws {
        try prepareDirectory()
        let url = manifestURL(in: entryDirectory(episodeID: episodeID, originalURL: originalURL))
        guard var manifest = try existingManifest(at: url) else {
            return
        }

        manifest.isCompleted = true
        manifest.lastAccess = .now
        try writeManifest(manifest, to: url)
    }

    func remove(episodeID: String) throws {
        try prepareDirectory()
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for entry in entries {
            let manifestURL = manifestURL(in: entry)
            guard let manifest = try? existingManifest(at: manifestURL),
                  manifest.episodeID == episodeID
            else {
                continue
            }
            try fileManager.removeItem(at: entry)
        }
    }

    func remove(podcastID: String) throws {
        try prepareDirectory()
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for entry in entries {
            let manifestURL = manifestURL(in: entry)
            guard let manifest = try? existingManifest(at: manifestURL),
                  manifest.podcastID == podcastID
            else {
                continue
            }
            try fileManager.removeItem(at: entry)
        }
    }

    func clear() throws {
        try prepareDirectory()
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }

    func summary() throws -> StreamingAudioCacheSummary {
        try prepareDirectory()
        var byteCount: Int64 = 0
        var fileCount = 0
        for fileURL in try recursiveFiles(in: directory) {
            byteCount += try fileSize(at: fileURL)
            fileCount += 1
        }
        return StreamingAudioCacheSummary(byteCount: byteCount, fileCount: fileCount)
    }

    func schedulePrune(byteBudget: Int64, delay: Duration = StreamingAudioDiskCache.scheduledPruneDelay) {
        guard scheduledPruneTask == nil else {
            return
        }

        scheduledPruneTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            await self?.runScheduledPrune(byteBudget: byteBudget)
        }
    }

    func prune(byteBudget: Int64, now: Date = .now) throws {
        try prepareDirectory()
        var entries = try cacheEntries()
        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        guard totalBytes > byteBudget else {
            return
        }

        entries.sort { lhs, rhs in
            if lhs.manifest.isCompleted != rhs.manifest.isCompleted {
                return lhs.manifest.isCompleted
            }
            return lhs.manifest.lastAccess < rhs.manifest.lastAccess
        }

        for entry in entries {
            try fileManager.removeItem(at: entry.directory)
            totalBytes -= entry.byteCount
            if totalBytes <= byteBudget {
                break
            }
        }
    }

    private func runScheduledPrune(byteBudget: Int64) {
        defer {
            scheduledPruneTask = nil
        }

        try? prune(byteBudget: byteBudget)
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(resourceValues)
    }

    private func validate(
        _ metadata: StreamingAudioRangeMetadata,
        against manifest: StreamingAudioCacheManifest
    ) throws {
        if let etag = manifest.etag,
           let responseETag = metadata.etag,
           etag != responseETag {
            throw StreamingAudioCacheError.validatorChanged
        }
        if let lastModified = manifest.lastModified,
           let responseLastModified = metadata.lastModified,
           lastModified != responseLastModified {
            throw StreamingAudioCacheError.validatorChanged
        }
        if !manifest.hasValidator && !metadata.hasValidator {
            throw StreamingAudioCacheError.missingValidator
        }
    }

    private func write(_ data: Data, to url: URL, at offset: Int64) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    private func entryDirectory(episodeID: String, originalURL: URL) -> URL {
        directory.appending(path: cacheKey(episodeID: episodeID, originalURL: originalURL), directoryHint: .isDirectory)
    }

    private func dataURL(in entryDirectory: URL) -> URL {
        entryDirectory.appending(path: "audio.data")
    }

    private func manifestURL(in entryDirectory: URL) -> URL {
        entryDirectory.appending(path: "manifest.json")
    }

    private func existingManifest(at url: URL) throws -> StreamingAudioCacheManifest? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try readManifest(at: url)
    }

    private func readManifest(at url: URL) throws -> StreamingAudioCacheManifest {
        try decoder.decode(StreamingAudioCacheManifest.self, from: Data(contentsOf: url))
    }

    private func writeManifest(_ manifest: StreamingAudioCacheManifest, to url: URL) throws {
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func cacheKey(episodeID: String, originalURL: URL) -> String {
        let source = "\(episodeID)|\(originalURL.absoluteString)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }

    private func cacheEntries() throws -> [StreamingAudioCacheEntry] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { entryDirectory in
                let manifestURL = manifestURL(in: entryDirectory)
                let dataURL = dataURL(in: entryDirectory)
                guard let manifest = try? existingManifest(at: manifestURL),
                      fileManager.fileExists(atPath: dataURL.path)
                else {
                    return nil
                }

                let byteCount = (try? dataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return StreamingAudioCacheEntry(
                    directory: entryDirectory,
                    byteCount: byteCount,
                    manifest: manifest
                )
            }
    }

    private func recursiveFiles(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
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

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}
