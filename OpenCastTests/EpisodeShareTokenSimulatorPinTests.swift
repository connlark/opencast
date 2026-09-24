import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

/// The `OpenCast` scheme never runs `OpenCastCoreTests`, so this suite
/// re-asserts the Core fixture on the simulator's own libz. The ShareWorker
/// decodes these exact tokens; if an OS update ever changes Apple's deflate
/// output, this fails and the vectors are re-minted after confirming the
/// worker still decodes them.
@MainActor
@Suite("Episode share token simulator pin")
struct EpisodeShareTokenSimulatorPinTests {
    private struct Fixture: Decodable {
        struct Payload: Decodable {
            let audioURL: String
            let title: String
            let podcastTitle: String
            let artworkURL: String
            let feedURL: String
            let guid: String
            let durationSeconds: Int
            let publishedUnix: Int
        }

        struct Vector: Decodable {
            let name: String
            let payload: Payload
            let token: String
            let startTime: Int
            let url: String
        }

        let vectors: [Vector]
    }

    @Test("Every fixture token encodes byte for byte on this runtime")
    func vectorsMatchOnSimulator() throws {
        let fixtureURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/EpisodeShareTokenVectors.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        #expect(fixture.vectors.count >= 7)

        for vector in fixture.vectors {
            let payload = try #require(EpisodeSharePayload(
                audioURL: vector.payload.audioURL,
                title: vector.payload.title,
                podcastTitle: vector.payload.podcastTitle,
                artworkURL: vector.payload.artworkURL,
                feedURL: vector.payload.feedURL,
                guid: vector.payload.guid,
                duration: TimeInterval(vector.payload.durationSeconds),
                publishedAt: Date(timeIntervalSince1970: TimeInterval(vector.payload.publishedUnix))
            ), "\(vector.name)")

            #expect(try EpisodeShareTokenEncoder.token(for: payload) == vector.token, "\(vector.name)")
            #expect(
                try EpisodeShareURL.url(
                    base: OpenCastConstants.episodeShareBaseURL,
                    payload: payload,
                    startSeconds: vector.startTime
                ).absoluteString == vector.url,
                "\(vector.name)"
            )
        }
    }
}
