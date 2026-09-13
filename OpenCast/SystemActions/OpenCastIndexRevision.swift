import CryptoKit
import Foundation

nonisolated struct OpenCastIndexRevision: Codable, Equatable, Sendable {
    var version = 1
    var shows: [String: String]
    var episodes: [String: String]

    init(catalog: OpenCastEntityCatalog) {
        shows = Dictionary(catalog.shows.map { ($0.id, Self.digest([$0.title])) }, uniquingKeysWith: { first, _ in first })
        episodes = Dictionary(catalog.episodes.map {
            ($0.id, Self.digest([$0.title, $0.showName ?? "", $0.show?.id ?? "", $0.releaseDate?.description ?? "", $0.duration?.description ?? ""]))
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func digest(_ fields: [String]) -> String {
        SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8)).description
    }
}
