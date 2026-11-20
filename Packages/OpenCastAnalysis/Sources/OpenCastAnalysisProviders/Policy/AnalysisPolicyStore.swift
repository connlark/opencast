import Foundation
import OpenCastAnalysis

/// Nothing here is secret; the bundle is re-verified every time it is read.
struct AnalysisPolicyStore: Sendable {
    struct Metadata: Codable, Equatable {
        var lastAttemptAt: Date?
        var lastFailure: AnalysisPolicyRejection?
        var highestAcceptedVersion = 0
    }

    /// One file, so the bundle, its signature and its date are always replaced together.
    struct CachedBundle: Codable, Equatable {
        var bundle: Data
        var signature: Data
        var confirmedAt: Date
    }

    let directory: URL

    private var cacheURL: URL { directory.appending(path: "analysis-policy.json") }
    private var metadataURL: URL { directory.appending(path: "analysis-policy-state.json") }

    func readCachedBundle() -> CachedBundle? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? Self.decoder.decode(CachedBundle.self, from: data)
    }

    func writeCachedBundle(_ cached: CachedBundle) throws {
        try prepareDirectory()
        try Self.encoder.encode(cached).write(to: cacheURL, options: .atomic)
    }

    func readMetadata() -> Metadata {
        guard let data = try? Data(contentsOf: metadataURL) else { return Metadata() }
        return (try? Self.decoder.decode(Metadata.self, from: data)) ?? Metadata()
    }

    func writeMetadata(_ metadata: Metadata) throws {
        try prepareDirectory()
        try Self.encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
