import Foundation
import NaturalLanguage
import Testing
@testable import OpenCast

/// Parity with the external evaluation harness on real show metadata: the
/// app's own line preparation (boilerplate snippets, show-wide title
/// prefixes) feeds the index, and the rankings and candidate windows must
/// match what the harness recorded. Every fixture name comes from the
/// manifest; failures report entry numbers, indices and counts, never titles.
@Suite("Episode metadata index on the evaluation corpus", .enabled(if: PlaylistEvaluationCorpus.isAvailable))
struct EpisodeMetadataCorpusTests {
    @Test("Every recorded BM25 ranking matches the index, scores within 1e-9")
    func rankingsMatchReference() throws {
        let manifest = try Self.manifest()
        let rankingsURL = try #require(PlaylistEvaluationCorpus.url(relativePath: manifest.rankings))
        let rankings = try JSONDecoder().decode([String: Ranking].self, from: Data(contentsOf: rankingsURL))
        var indexes: [String: EpisodeMetadataIndex] = [:]
        var checked = 0

        for (entry, key) in rankings.keys.sorted().enumerated() {
            guard let separator = key.firstIndex(of: "|"), let expected = rankings[key] else {
                Issue.record("Rankings entry \(entry) has no fixture separator.")
                continue
            }
            let fixture = String(key[..<separator])
            let query = String(key[key.index(after: separator)...])
            let index = try Self.index(for: fixture, cache: &indexes)
            let actual = index.search(query, limit: .max)
            checked += 1

            #expect(expected.ranking.count == expected.scores.count, "rankings entry \(entry)")
            #expect(actual.count == expected.ranking.count, "rankings entry \(entry)")
            let positions = zip(actual.map(\.position), expected.ranking)
            if let mismatch = positions.enumerated().first(where: { $0.element.0 != $0.element.1 }) {
                Issue.record(
                    "Rankings entry \(entry): rank \(mismatch.offset) is index \(mismatch.element.0), expected \(mismatch.element.1)."
                )
            }
            let scoreMisses = zip(actual, expected.scores).filter { abs($0.score - $1) > 1e-9 }
            #expect(
                scoreMisses.isEmpty,
                "rankings entry \(entry): \(scoreMisses.count) scores differ, first at index \(scoreMisses.first?.0.position ?? -1)"
            )
        }
        #expect(checked > 0)
    }

    @Test("Every recorded candidate window matches the catalog's ranked positions")
    func windowsMatchReference() async throws {
        let manifest = try Self.manifest()
        #expect(!manifest.windows.isEmpty)
        var catalogs: [String: PlaylistOrganizerCatalog] = [:]

        for (entry, window) in manifest.windows.enumerated() {
            let expectedURL = try #require(PlaylistEvaluationCorpus.url(relativePath: window.expected))
            let expected = try JSONDecoder().decode([Int].self, from: Data(contentsOf: expectedURL))
            let catalog = try await Self.catalog(for: window.fixture, cache: &catalogs)

            let actual = await catalog.window(for: window.request)

            if catalog.vectorIndex == nil {
                Issue.record(
                    "No word embedding for language \(catalog.language.rawValue); window entry \(entry) compared its lexical block only."
                )
                #expect(actual.fillCount == 0, "window entry \(entry)")
                #expect(actual.rankedPositions == Array(expected.prefix(actual.lexicalCount)), "window entry \(entry)")
            } else {
                // The lexical block is exact. The fill is compared as a set:
                // lines with identical vectors tie on similarity, and the last
                // bit of that product differs between platforms, so their
                // order is not portable. Lines are sent in index order anyway.
                let lexicalCount = actual.lexicalCount
                #expect(
                    Array(actual.rankedPositions.prefix(lexicalCount)) == Array(expected.prefix(lexicalCount)),
                    "window entry \(entry): lexical block of \(lexicalCount)"
                )
                #expect(
                    actual.positions == expected.sorted(),
                    "window entry \(entry): lexical \(lexicalCount), fill \(actual.fillCount), expected \(expected.count)"
                )
            }
            #expect(actual.positions == actual.rankedPositions.sorted(), "window entry \(entry)")
        }
    }

    // MARK: - Inputs

    private static func manifest() throws -> Manifest {
        let url = try #require(PlaylistEvaluationCorpus.manifestURL)
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private static func episodes(for fixture: String) throws -> [PlaylistOrganizerEpisode] {
        let url = try #require(PlaylistEvaluationCorpus.fixtureURL(named: fixture))
        let file = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        return file.episodes.map { episode in
            PlaylistOrganizerEpisode(
                index: episode.index,
                episodeID: "corpus-\(episode.index)",
                publishedAt: episode.published.flatMap { try? Date($0, strategy: .iso8601) },
                duration: episode.durationSeconds,
                title: episode.title,
                snippet: episode.snippet?.isEmpty == false ? episode.snippet : nil
            )
        }
    }

    private static func index(
        for fixture: String,
        cache: inout [String: EpisodeMetadataIndex]
    ) throws -> EpisodeMetadataIndex {
        if let index = cache[fixture] {
            return index
        }
        let lines = try PlaylistOrganizerInputBuilder.metadataLines(for: episodes(for: fixture))
        let index = EpisodeMetadataIndex(lines: lines)
        cache[fixture] = index
        return index
    }

    private static func catalog(
        for fixture: String,
        cache: inout [String: PlaylistOrganizerCatalog]
    ) async throws -> PlaylistOrganizerCatalog {
        if let catalog = cache[fixture] {
            return catalog
        }
        let catalog = try await PlaylistOrganizerCatalog.build(episodes: episodes(for: fixture))
        cache[fixture] = catalog
        return catalog
    }

    private struct Manifest: Decodable {
        var rankings: String
        var windows: [Window]
    }

    private struct Window: Decodable {
        var fixture: String
        var request: String
        var expected: String
    }

    private struct Ranking: Decodable {
        var ranking: [Int]
        var scores: [Double]
    }

    private struct Fixture: Decodable {
        var episodes: [FixtureEpisode]
    }

    private struct FixtureEpisode: Decodable {
        var index: Int
        var published: String?
        var durationSeconds: Double?
        var title: String
        var snippet: String?

        private enum CodingKeys: String, CodingKey {
            case index, published, title, snippet
            case durationSeconds = "duration_seconds"
        }
    }
}
