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
        #expect(window.isInformative)

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
        #expect(window.positions == window.rankedPositions.sorted())
        #expect(Set(window.rankedPositions).count == window.rankedPositions.count)
        #expect(window.lexicalCount == 3)
        #expect(window.fillCount == 4)
        #expect(window.isInformative)
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

        let production = EpisodeCandidateRanking.lexicalFirst(
            lexical: matches(Array(0..<200)),
            semantic: matches(Array((0..<400).reversed()))
        )
        #expect(EpisodeCandidateRanking.defaultLexicalLimit == 150)
        #expect(EpisodeCandidateRanking.defaultFill == 30)
        #expect(Array(production.rankedPositions.prefix(150)) == Array(0..<150))
        #expect(Array(production.rankedPositions.dropFirst(150)) == Array((370..<400).reversed()))
        #expect(production.lexicalCount == 150)
        #expect(production.fillCount == 30)
        #expect(Set(production.positions).count == 180)
    }

    @Test("With no semantic ranking the window is the lexical block alone")
    func emptySemanticKeepsLexicalBlock() {
        let window = EpisodeCandidateRanking.lexicalFirst(lexical: matches([9, 2, 5]), semantic: [])

        #expect(window.rankedPositions == [9, 2, 5])
        #expect(window.positions == [2, 5, 9])
        #expect(window.lexicalCount == 3)
        #expect(window.fillCount == 0)
        #expect(window.isInformative)
    }

    @Test("With no lexical block the fill alone forms an uninformative window")
    func emptyLexicalIsUninformative() {
        let window = EpisodeCandidateRanking.lexicalFirst(lexical: [], semantic: matches([5, 1, 9]), fill: 2)

        #expect(window.rankedPositions == [5, 1])
        #expect(window.positions == [1, 5])
        #expect(window.lexicalCount == 0)
        #expect(window.fillCount == 2)
        #expect(!window.isInformative)
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

    @Test("The scope's prompt text uses plain digits for each kind")
    func scopePromptText() {
        #expect(PlaylistOrganizerScope(kind: .all, sentCount: 1_109, totalCount: 1_109).promptText == "all 1109")
        #expect(
            PlaylistOrganizerScope(kind: .bestMatches, sentCount: 57, totalCount: 1_109).promptText
                == "the 57 of 1109 that best match the request"
        )
        #expect(
            PlaylistOrganizerScope(kind: .newest, sentCount: 700, totalCount: 1_109).promptText
                == "the newest 700 of 1109"
        )
    }

    /// Scores descend with rank so the order reads as a ranking.
    private func matches(_ positions: [Int]) -> [EpisodeMetadataMatch] {
        positions.enumerated().map { rank, position in
            EpisodeMetadataMatch(position: position, score: Double(positions.count - rank))
        }
    }
}
