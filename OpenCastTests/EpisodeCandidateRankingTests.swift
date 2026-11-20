import Foundation
import NaturalLanguage
import Testing
@testable import OpenCast

@Suite("Episode candidate ranking")
struct EpisodeCandidateRankingTests {
    @Test("A catalog without word vectors answers with the lexical block alone")
    func catalogWithoutVectorsIsLexicalOnly() async {
        let lines = (0..<12).map { position in
            let title = position.isMultiple(of: 4) ? "Lighthouse keepers \(position)" : "Harbor notes \(position)"
            return EpisodeMetadataLine(position: position, lexicalText: title, semanticText: title)
        }
        let catalog = PlaylistOrganizerCatalog(
            lines: lines,
            lexicalIndex: EpisodeMetadataIndex(lines: lines),
            vectorIndex: nil,
            language: .english
        )

        let window = await catalog.window(for: "lighthouse")
        #expect(window.rankedPositions == [0, 4, 8])
        #expect(window.lexicalCount == 3)
        #expect(window.fillCount == 0)

        let additions = await catalog.additions(for: "lighthouse", excluding: [4], limit: 30)
        #expect(additions == [0, 8])
    }

    @Test("The window is the lexical block in its order, then exactly the fill, sent ascending without duplicates")
    func lexicalBlockThenFill() {
        let window = EpisodeCandidateRanking.lexicalFirst(
            lexical: matches([40, 7, 19]),
            semantic: matches([7, 2, 40, 55, 3, 19, 80, 11, 60]),
            fill: 4,
            limit: 150
        )

        #expect(window.rankedPositions == [40, 7, 19, 2, 55, 3, 80])
        #expect(window.positions == [2, 3, 7, 19, 40, 55, 80])
        #expect(window.lexicalCount == 3)
        #expect(window.fillCount == 4)
    }

    @Test("The lexical block caps at the limit and the fill never displaces it")
    func lexicalBlockCapsAtLimit() {
        let capped = EpisodeCandidateRanking.lexicalFirst(
            lexical: matches([10, 11, 12, 13, 14, 15, 16, 17]),
            semantic: matches([12, 30, 31, 32]),
            fill: 2,
            limit: 4
        )
        #expect(capped.rankedPositions == [10, 11, 12, 13, 30, 31])
        #expect(capped.lexicalCount == 4)
        #expect(capped.fillCount == 2)
    }

    @Test("The fill skips lexical members and excluded positions, and exclusion also filters the lexical block")
    func fillSkipsTakenAndExcluded() {
        let window = EpisodeCandidateRanking.lexicalFirst(
            lexical: matches([4, 8, 12]),
            semantic: matches([4, 1, 8, 2, 12, 3, 6, 9]),
            fill: 2,
            excluding: [8, 1, 3]
        )

        #expect(window.rankedPositions == [4, 12, 2, 6])
        #expect(window.positions == [2, 4, 6, 12])
        #expect(window.lexicalCount == 2)
        #expect(window.fillCount == 2)

        let short = EpisodeCandidateRanking.lexicalFirst(
            lexical: matches([4]),
            semantic: matches([4, 7, 6]),
            fill: 30
        )
        #expect(short.rankedPositions == [4, 7, 6])
        #expect(short.fillCount == 2)
    }

    private func matches(_ positions: [Int]) -> [EpisodeMetadataMatch] {
        positions.enumerated().map { rank, position in
            EpisodeMetadataMatch(position: position, score: Double(positions.count - rank))
        }
    }
}
