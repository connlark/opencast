import Foundation
import Testing
@testable import OpenCast

/// Expected tokens and scores come from the external evaluation harness's
/// reference BM25 run over the same twelve lines, so the index is held to it
/// digit for digit.
@Suite("Episode metadata index")
struct EpisodeMetadataIndexTests {
    @Test("Tokens drop a possessive before a space, fold diacritics and keep digits")
    func tokenizerFoldsAndSplits() {
        #expect(EpisodeMetadataTokenizer.tokens(in: "The Captain's Log") == ["captain", "log"])
        #expect(EpisodeMetadataTokenizer.tokens(in: "The Captain’s Log") == ["captain", "log"])
        #expect(EpisodeMetadataTokenizer.tokens(in: "Notes from the Captain's") == ["note", "captain", "s"])
        #expect(EpisodeMetadataTokenizer.tokens(in: "Café Crème Brûlée naïve") == ["cafe", "creme", "brulee", "naive"])
        #expect(EpisodeMetadataTokenizer.tokens(in: "Łódź and Æsir") == ["odz", "sir"])
        #expect(EpisodeMetadataTokenizer.tokens(in: "1999 Top 40 Hits, Vol. 2") == ["1999", "top", "40", "hit", "vol", "2"])
        #expect(EpisodeMetadataTokenizer.tokens(in: "") == [])
        #expect(EpisodeMetadataTokenizer.tokens(in: "the and of a") == [])
    }

    @Test("Unicode separators preserve searchable words", arguments: ["—", "–", "…", "·", "“", "”", "／", "\u{2003}", "🎙️"])
    func unicodeWordBoundaries(separator: String) {
        let title = "Rome\(separator)The Republic"
        #expect(EpisodeMetadataTokenizer.tokens(in: title) == ["rome", "republic"])
        let index = EpisodeMetadataIndex(lines: [line(0, title), line(1, "Garden Notes")])
        #expect(index.search("Rome", limit: .max).map(\.position) == [0])
        #expect(index.search(title, limit: .max).map(\.position) == [0])
    }

    @Test("The stop list applies to the raw token, before stemming")
    func stopListBeforeStemming() {
        #expect(EpisodeMetadataTokenizer.tokens(in: "Make Makes Episodes Episodic Thes") == ["make", "episodic", "the"])
    }

    @Test("Stemming turns a long ies into y and drops a plain plural s, with no sses rule")
    func stemmer() {
        #expect(EpisodeMetadataTokenizer.tokens(in: "Stories Series Pies Ties") == ["story", "sery", "pie", "tie"])
        #expect(
            EpisodeMetadataTokenizer.tokens(in: "Glasses Classes Buses Bus Basis Class")
                == ["glasse", "classe", "buse", "bus", "basis", "class"]
        )
        #expect(EpisodeMetadataTokenizer.stem("stories") == "story")
        #expect(EpisodeMetadataTokenizer.stem("pies") == "pie")
        #expect(EpisodeMetadataTokenizer.stem("glasses") == "glasse")
        #expect(EpisodeMetadataTokenizer.stem("status") == "status")
    }

    @Test("Query terms are unique and keep their first-occurrence order")
    func queryTermsKeepFirstOccurrenceOrder() {
        #expect(
            EpisodeMetadataTokenizer.queryTerms("harbor lights, harbor ships and the harbor")
                == ["harbor", "light", "ship"]
        )
        #expect(EpisodeMetadataTokenizer.tokens(in: "Harbor lights harbor ships HARBOR") == ["harbor", "light", "harbor", "ship", "harbor"])
        #expect(EpisodeMetadataTokenizer.stopWords.count == 37)
    }

    @Test("BM25 ranks the twelve-line fixture exactly as the reference does, ties by position")
    func bm25MatchesReference() {
        let index = EpisodeMetadataIndex(lines: Self.lines)
        #expect(index.documentCount == 12)

        expect(
            index.search("lighthouse harbor", limit: .max),
            positions: [1, 0, 10, 11, 4, 2],
            scores: [
                1.810246069617658,
                1.6766577023346332,
                1.3997652865754338,
                1.3997652865754338,
                1.3185322661830927,
                1.1230153534859204,
            ]
        )
        expect(
            index.search("glass boats harbor", limit: .max),
            positions: [10, 0, 2, 11, 4, 8],
            scores: [
                3.158459884321243,
                2.8580676914375394,
                1.410980150960368,
                1.3997652865754338,
                1.3185322661830927,
                1.246210537006976,
            ]
        )
        expect(
            index.search("the lighthouses and the lighthouse", limit: .max),
            positions: [1, 4, 2],
            scores: [1.810246069617658, 1.3185322661830927, 1.1230153534859204]
        )
        expect(
            index.search("tomatoes", limit: .max),
            positions: [6, 7],
            scores: [1.7586945977458093, 1.7586945977458093]
        )
        #expect(index.search("lighthouse harbor", limit: 2).map(\.position) == [1, 0])
        #expect(index.search("zebra", limit: .max).isEmpty)
        #expect(index.search("the and of", limit: .max).isEmpty)
        #expect(index.search("lighthouse", limit: 0).isEmpty)
    }

    @Test("A request is informative only through a term in at least one and at most half the lines")
    func informativeness() {
        let index = EpisodeMetadataIndex(lines: [
            line(0, "Weekly harbor news"),
            line(1, "Weekly garden news"),
            line(2, "Weekly harbor bread news"),
            line(3, "Weekly ferry news"),
        ])

        #expect(!index.isInformative("weekly"))
        #expect(!index.isInformative("weekly news"))
        #expect(!index.isInformative("zebra"))
        #expect(!index.isInformative("the and of"))
        #expect(index.isInformative("ferry"))
        #expect(index.isInformative("harbor"))
        #expect(index.isInformative("weekly ferry news"))
        #expect(index.informativeTerms("weekly ferries zebra harbor") == ["ferry", "harbor"])

        let everyLine = index.search("weekly ferry", limit: .max)
        #expect(everyLine.count == 4)
        #expect(everyLine.first?.position == 3)
        #expect(index.informativeMatches("weekly ferry").map(\.position) == [3])
        #expect(index.informativeMatches("weekly news").isEmpty)
    }

    @Test("Two builds over the same lines answer identically")
    func buildsAreDeterministic() {
        let first = EpisodeMetadataIndex(lines: Self.lines)
        let second = EpisodeMetadataIndex(lines: Self.lines)
        for query in ["lighthouse harbor", "glass boats harbor", "garden tomatoes herbs", "night ferry crossing"] {
            #expect(first.search(query, limit: .max) == second.search(query, limit: .max))
            #expect(first.informativeMatches(query) == second.informativeMatches(query))
            #expect(first.informativeTerms(query) == second.informativeTerms(query))
        }
    }

    private static let lines: [EpisodeMetadataLine] = [
        ("Harbor Lights at Dusk", "Fishing boats return to the harbor as the lamps come on."),
        ("The Lighthouse Keeper", "A keeper's diary from a lonely lighthouse on the cape."),
        ("Lighthouse Lenses Explained", "How glass lenses throw a beam across the water."),
        ("Morning Tides", "Reading tide tables before a long paddle."),
        ("Storm Season", "Preparing boats and lighthouses for winter storms."),
        ("Bread and Butter", "Baking simple loaves at home."),
        ("Garden Notes", "Planting tomatoes and herbs in spring."),
        ("Garden Notes Again", "Watering tomatoes and herbs."),
        ("The Old Pier", "Stories from the pier and the boats that tied up there."),
        ("Night Ferries", "Crossing the strait on the last ferry."),
        ("Lantern Makers", "Glass, brass and the lamps of the harbor."),
        ("Quiet Coves", "Small harbors along the coast."),
    ].enumerated().map { position, entry in
        EpisodeMetadataLine(
            position: position,
            lexicalText: entry.0 + " " + entry.1,
            semanticText: entry.0 + ". " + entry.1
        )
    }

    private func line(_ position: Int, _ text: String) -> EpisodeMetadataLine {
        EpisodeMetadataLine(position: position, lexicalText: text, semanticText: text)
    }

    private func expect(
        _ matches: [EpisodeMetadataMatch],
        positions: [Int],
        scores: [Double],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(matches.map(\.position) == positions, sourceLocation: sourceLocation)
        #expect(matches.count == scores.count, sourceLocation: sourceLocation)
        for (match, score) in zip(matches, scores) {
            #expect(abs(match.score - score) <= 1e-9, "position \(match.position)", sourceLocation: sourceLocation)
        }
    }
}
