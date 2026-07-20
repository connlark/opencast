import Foundation
import Testing
@testable import OpenCastTranscription

/// Decodes the committed golden stitch fixture and reproduces its normalized
/// transcript hash in Swift. The Rust stitcher runs the same checks from the
/// same file; together they are the golden-parity gate.
@Suite("Remote transcription golden stitch fixture")
struct OpenCastRemoteTranscriptionGoldenFixtureTests {
    struct Fixture: Decodable {
        struct Contract: Decodable {
            let chunkSeconds: Double
            let overlapSeconds: Double
            let stepSeconds: Double
            let dedupeEpsilonSeconds: Double
            let pipelineVersion: String

            enum CodingKeys: String, CodingKey {
                case chunkSeconds = "chunk_seconds"
                case overlapSeconds = "overlap_seconds"
                case stepSeconds = "step_seconds"
                case dedupeEpsilonSeconds = "dedupe_epsilon_seconds"
                case pipelineVersion = "pipeline_version"
            }
        }

        struct Source: Decodable {
            let sha256: String?
            let byteCount: Int64?
            let durationSeconds: Double?
            let debugJobID: String?
            let responseCount: Int?

            enum CodingKeys: String, CodingKey {
                case sha256
                case byteCount = "byte_count"
                case durationSeconds = "duration_seconds"
                case debugJobID = "debug_job_id"
                case responseCount = "response_count"
            }
        }

        struct Word: Decodable {
            let text: String
            let start: Double
            let end: Double
        }

        struct Segment: Decodable {
            let id: Int
            let start: Double
            let end: Double
            let text: String
            let words: [Word]
        }

        struct Seam: Decodable {
            let ownershipBoundarySeconds: Double
            let boundaryGapSeconds: Double?

            enum CodingKeys: String, CodingKey {
                case ownershipBoundarySeconds = "ownership_boundary_seconds"
                case boundaryGapSeconds = "boundary_gap_seconds"
            }
        }

        struct Chunk: Decodable {
            let index: Int
            let requestedStartSeconds: Double

            enum CodingKeys: String, CodingKey {
                case index
                case requestedStartSeconds = "requested_start_seconds"
            }
        }

        struct Expected: Decodable {
            let segments: [Segment]
            let seams: [Seam]
            let stitchedWordCount: Int
            let deduplicatedWordCount: Int
            let normalizedTranscriptSHA256: String

            enum CodingKeys: String, CodingKey {
                case segments
                case seams
                case stitchedWordCount = "stitched_word_count"
                case deduplicatedWordCount = "deduplicated_word_count"
                case normalizedTranscriptSHA256 = "normalized_transcript_sha256"
            }
        }

        let schemaVersion: Int
        let contract: Contract
        let source: Source
        let chunks: [Chunk]
        let expected: Expected

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case contract
            case source
            case chunks
            case expected
        }
    }

    static let fixtureNames = [
        "RemoteTranscriptionGoldenStitch.json",
        "RemoteTranscriptionSeamDuplicateStitch.json",
    ]

    static func loadFixture(named fixtureName: String) throws -> Fixture {
        // Loaded relative to this source file, NOT via a test-target
        // `resources:` declaration: adding resources to the test target
        // generates a test-local `Bundle.module` that shadows the main
        // module's, silently inverting the resource-bundle tests
        // (`OpenCastTranscriptionResourceTests`) that rely on `@testable`
        // resolution to the shipping bundle.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(fixtureName)")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("Fixtures match stitch v2 and their pinned sources")
    func fixturesMatchChunkContract() throws {
        let fixture = try Self.loadFixture(named: Self.fixtureNames[0])
        #expect(fixture.schemaVersion == 2)
        #expect(fixture.contract.chunkSeconds == 300)
        #expect(fixture.contract.overlapSeconds == 2)
        #expect(fixture.contract.stepSeconds == 298)
        #expect(fixture.contract.dedupeEpsilonSeconds == 0.9)
        #expect(fixture.contract.pipelineVersion == "stitch-v2")
        #expect(fixture.source.sha256
            == "da26a00f82f4edfcfc133ab06ce4d89d2af5864b28a2c039d55dea1c7b5f8699")
        #expect(fixture.source.byteCount == 16_328_368)
        #expect(fixture.chunks.count == 7)
        #expect(fixture.expected.seams.count == 6)
        for (index, chunk) in fixture.chunks.enumerated() {
            #expect(chunk.index == index)
            #expect(chunk.requestedStartSeconds == Double(index) * 298)
        }

        let duplicateFixture = try Self.loadFixture(named: Self.fixtureNames[1])
        #expect(duplicateFixture.schemaVersion == 2)
        #expect(duplicateFixture.contract.dedupeEpsilonSeconds == 0.9)
        #expect(duplicateFixture.contract.pipelineVersion == "stitch-v2")
        #expect(duplicateFixture.source.debugJobID == "job-4jODJ84DNjOpsQkcAn6ehw")
        #expect(duplicateFixture.source.responseCount == 14)
        #expect(duplicateFixture.chunks.count == 14)
        #expect(duplicateFixture.expected.seams.count == 13)
        #expect(duplicateFixture.expected.deduplicatedWordCount == 3)
    }

    @Test("Stitched words are ordered, in range, and cover both seam sides")
    func stitchedWordsAreOrderedAndInRange() throws {
        for fixtureName in Self.fixtureNames {
            let fixture = try Self.loadFixture(named: fixtureName)
            let words = fixture.expected.segments.flatMap(\.words)
            #expect(words.count == fixture.expected.stitchedWordCount)
            for (previous, next) in zip(words, words.dropFirst()) {
                #expect(next.start + 0.001 >= previous.start)
            }
            for word in words {
                #expect(word.start.isFinite && word.end.isFinite)
                #expect(word.start >= 0)
                if let durationSeconds = fixture.source.durationSeconds {
                    #expect(word.end <= durationSeconds + 0.5)
                }
            }
            for seam in fixture.expected.seams {
                let boundary = seam.ownershipBoundarySeconds
                #expect(words.contains { ($0.start + $0.end) / 2 < boundary })
                #expect(words.contains { ($0.start + $0.end) / 2 >= boundary })
                if let gap = seam.boundaryGapSeconds {
                    #expect(abs(gap) < 1.5)
                }
            }
        }
    }

    @Test("Segment text is exactly its words joined by single spaces")
    func segmentTextMatchesWords() throws {
        for fixtureName in Self.fixtureNames {
            let fixture = try Self.loadFixture(named: fixtureName)
            for segment in fixture.expected.segments {
                #expect(!segment.words.isEmpty)
                #expect(segment.text == segment.words.map(\.text).joined(separator: " "))
                #expect(segment.start <= segment.end)
            }
        }
    }

    @Test("Swift normalization reproduces the fixture's normalized hash")
    func normalizationReproducesFixtureHash() throws {
        for fixtureName in Self.fixtureNames {
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
    }

    @Test("Observed duplicates are removed without collapsing a real restart")
    func observedSeamDuplicates() throws {
        let fixture = try Self.loadFixture(named: Self.fixtureNames[1])
        let normalizedWords = fixture.expected.segments
            .flatMap(\.words)
            .flatMap { OpenCastRemoteTranscriptNormalization.normalizedTokens($0.text) }
        #expect(normalizedWords.count(where: { $0 == "prescriptive" }) == 1)
        #expect(normalizedWords.count(where: { $0 == "improvs" }) == 1)
        #expect(normalizedWords.count(where: { $0 == "beckon" }) == 1)
        #expect(normalizedWords.count(where: { $0 == "that" }) == 2)
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
