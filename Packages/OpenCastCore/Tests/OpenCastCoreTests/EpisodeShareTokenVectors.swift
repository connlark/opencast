import Foundation
import OpenCastCore
import Testing

/// `Fixtures/EpisodeShareTokenVectors.json`, shared with the ShareWorker's
/// vitest suite. Swift is the reference encoder: the worker decodes these
/// tokens but never compares its own zlib output to them byte for byte.
struct EpisodeShareTokenVectors: Codable {
    struct DictionaryPin: Codable {
        let utf8Bytes: Int
        let sha256: String
    }

    struct Payload: Codable {
        let audioURL: String
        let title: String
        let podcastTitle: String
        let artworkURL: String
        let feedURL: String
        let guid: String
        let durationSeconds: Int
        let publishedUnix: Int

        var fields: [String] {
            [
                audioURL,
                title,
                podcastTitle,
                artworkURL,
                feedURL,
                guid,
                String(durationSeconds),
                String(publishedUnix)
            ]
        }

        /// Goes through the sanitising initialiser, so a fixture payload that
        /// the app could never produce fails here instead of in the worker.
        func sharePayload() throws -> EpisodeSharePayload {
            try #require(EpisodeSharePayload(
                audioURL: audioURL,
                title: title,
                podcastTitle: podcastTitle,
                artworkURL: artworkURL,
                feedURL: feedURL,
                guid: guid,
                duration: TimeInterval(durationSeconds),
                publishedAt: Date(timeIntervalSince1970: TimeInterval(publishedUnix))
            ))
        }
    }

    struct Vector: Codable {
        let name: String
        let payload: Payload
        let token: String
        let startTime: Int
        let url: String
        let maxTokenLength: Int
    }

    static let dictionarySensitivityVectorName = "dictionary-sensitivity"
    static let shareBaseURL = URL(string: "https://opencast.mobile/e/")!

    let format: String
    let version: String
    let dictionary: DictionaryPin
    let vectors: [Vector]

    static func load() throws -> EpisodeShareTokenVectors {
        let url = try #require(Bundle.module.url(forResource: "EpisodeShareTokenVectors", withExtension: "json"))
        return try JSONDecoder().decode(EpisodeShareTokenVectors.self, from: Data(contentsOf: url))
    }
}
