import Foundation
import Testing
@testable import OpenCastTranscription

@Suite("Remote transcription golden stitch fixture")
struct OpenCastRemoteTranscriptionGoldenFixtureTests {
    struct Fixture: Decodable {
        struct Word: Decodable {
            let text: String
        }

        struct Segment: Decodable {
            let words: [Word]
        }

        struct Expected: Decodable {
            let segments: [Segment]
            let normalizedTranscriptSHA256: String

            enum CodingKeys: String, CodingKey {
                case segments
                case normalizedTranscriptSHA256 = "normalized_transcript_sha256"
            }
        }

        let expected: Expected
    }

    static func loadFixture(named fixtureName: String) throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(fixtureName)")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test(
        "Swift normalization reproduces the fixture's normalized hash",
        arguments: ["RemoteTranscriptionGoldenStitch.json", "RemoteTranscriptionSeamDuplicateStitch.json"]
    )
    func normalizationReproducesFixtureHash(fixtureName: String) throws {
        let fixture = try Self.loadFixture(named: fixtureName)
        let stitchedText = fixture.expected.segments
            .flatMap(\.words)
            .map(\.text)
            .joined(separator: " ")
        #expect(
            OpenCastRemoteTranscriptNormalization.normalizedTranscriptSHA256(stitchedText)
                == fixture.expected.normalizedTranscriptSHA256
        )
    }

    @Test("Normalization matches the bakeoff rules on tricky input")
    func normalizationRules() {
        #expect(OpenCastRemoteTranscriptNormalization.normalizedTokens(
            "It\u{2019}s 3,000 Bugs — don't panic!") == ["its", "3000", "bugs", "dont", "panic"])
        #expect(OpenCastRemoteTranscriptNormalization.normalizedTokens("1,2,3") == ["12", "3"])
        #expect(OpenCastRemoteTranscriptNormalization.normalizedTokens("1,234,567") == ["1234567"])
        #expect(OpenCastRemoteTranscriptNormalization.normalizedTokens("  ") == [])
    }
}
