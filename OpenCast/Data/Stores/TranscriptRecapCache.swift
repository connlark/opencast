import Foundation

/// Device-local JSON store for completed recaps, one file per cache key under
/// Application Support. Entries are disposable: a changed transcript simply
/// stops matching, the data nuke removes everything, and the oldest files
/// are pruned past the cap.
nonisolated struct TranscriptRecapCache: Sendable {
    static let defaultDirectory = URL.applicationSupportDirectory
        .appending(path: "TranscriptRecaps", directoryHint: .isDirectory)
    static let maximumEntryCount = 200

    let directory: URL

    init(directory: URL = defaultDirectory) {
        self.directory = directory
    }

    func entry(for key: TranscriptRecapCacheKey) throws -> TranscriptRecapCacheEntry? {
        let url = directory.appending(path: key.fileName)
        guard FileManager.default.fileExists(atPath: url.path()) else {
            return nil
        }
        let entry = try Self.decoder.decode(TranscriptRecapCacheEntry.self, from: Data(contentsOf: url))
        // A hash collision or a hand-edited file must never surface another
        // episode's recap.
        return entry.key == key ? entry : nil
    }

    func store(_ entry: TranscriptRecapCacheEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(entry)
        try data.write(to: directory.appending(path: entry.key.fileName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try prune()
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path()) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func prune() throws {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        guard urls.count > Self.maximumEntryCount else {
            return
        }
        let dated = urls.map { url in
            (url: url, date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date < $1.date }
        for entry in dated.prefix(urls.count - Self.maximumEntryCount) {
            try FileManager.default.removeItem(at: entry.url)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
