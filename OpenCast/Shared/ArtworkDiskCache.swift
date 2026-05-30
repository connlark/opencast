import CryptoKit
import Foundation
import OpenCastCore

actor ArtworkDiskCache {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        directory: URL = OpenCastCacheController.defaultArtworkCacheDirectory(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func cachedEntry(for url: URL, now: Date = .now) throws -> ArtworkDiskCacheEntry? {
        try prepareDirectory()
        let key = cacheKey(for: url)
        let dataURL = dataURL(forKey: key)
        let metadataURL = metadataURL(forKey: key)
        guard fileManager.fileExists(atPath: dataURL.path),
              fileManager.fileExists(atPath: metadataURL.path)
        else {
            return nil
        }

        do {
            let data = try Data(contentsOf: dataURL)
            var metadata = try readMetadata(at: metadataURL)
            metadata.byteCount = data.count
            metadata.lastAccess = now
            try writeMetadata(metadata, to: metadataURL)
            return ArtworkDiskCacheEntry(data: data, metadata: metadata)
        } catch {
            removeCachedFiles(forKey: key)
            return nil
        }
    }

    func store(
        data: Data,
        response: OpenCastHTTPResponse,
        for url: URL,
        now: Date = .now
    ) throws -> ArtworkDiskCacheMetadata {
        try prepareDirectory()
        let key = cacheKey(for: url)
        let metadata = ArtworkDiskCacheMetadata(
            canonicalURL: URLCanonicalizer.canonicalString(for: url),
            sourceURL: url.absoluteString,
            mimeType: response.mimeType,
            etag: response.headerValue("etag"),
            lastModified: response.headerValue("last-modified"),
            byteCount: data.count,
            lastAccess: now,
            lastValidation: now
        )

        try data.write(to: dataURL(forKey: key), options: .atomic)
        try writeMetadata(metadata, to: metadataURL(forKey: key))
        return metadata
    }

    func updateValidation(
        for url: URL,
        response: OpenCastHTTPResponse,
        now: Date = .now
    ) throws {
        try prepareDirectory()
        let key = cacheKey(for: url)
        let url = metadataURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        var metadata = try readMetadata(at: url)
        metadata.mimeType = response.mimeType ?? metadata.mimeType
        metadata.etag = response.headerValue("etag") ?? metadata.etag
        metadata.lastModified = response.headerValue("last-modified") ?? metadata.lastModified
        metadata.lastAccess = now
        metadata.lastValidation = now
        try writeMetadata(metadata, to: url)
    }

    func metadata(for url: URL) throws -> ArtworkDiskCacheMetadata? {
        try prepareDirectory()
        let url = metadataURL(forKey: cacheKey(for: url))
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        return try readMetadata(at: url)
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }

    func remove(for url: URL) throws {
        removeCachedFiles(forKey: cacheKey(for: url))
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(resourceValues)
    }

    private func dataURL(forKey key: String) -> URL {
        directory.appending(path: "\(key).data")
    }

    private func metadataURL(forKey key: String) -> URL {
        directory.appending(path: "\(key).json")
    }

    private func removeCachedFiles(forKey key: String) {
        for url in [dataURL(forKey: key), metadataURL(forKey: key)] where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func cacheKey(for url: URL) -> String {
        let canonicalURL = URLCanonicalizer.canonicalString(for: url)
        let digest = SHA256.hash(data: Data(canonicalURL.utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }

    private func readMetadata(at url: URL) throws -> ArtworkDiskCacheMetadata {
        try decoder.decode(ArtworkDiskCacheMetadata.self, from: Data(contentsOf: url))
    }

    private func writeMetadata(_ metadata: ArtworkDiskCacheMetadata, to url: URL) throws {
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }
}
