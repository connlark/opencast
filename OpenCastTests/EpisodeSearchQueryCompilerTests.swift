import Testing
@testable import OpenCast

@Suite("Episode search query compiler")
struct EpisodeSearchQueryCompilerTests {
    @Test("Hostile FTS syntax is reduced to quoted literals")
    func hostileSyntaxIsReducedToQuotedLiterals() throws {
        let compiled = try #require(
            EpisodeSearchQueryCompiler.compile(
                "\"OR\" NEAR(5) *",
                mode: .fullText
            )
        )
        let exact = try #require(compiled.primaryChannels.first)

        #expect(exact.matchExpression.contains("\"or\""))
        #expect(exact.matchExpression.contains("\"near\""))
        #expect(exact.matchExpression.contains("\"5\""))
        #expect(!exact.matchExpression.contains("NEAR("))
        #expect(!exact.matchExpression.contains("\"OR\""))
    }

    @Test("Only an unfinished final token receives prefix syntax")
    func onlyUnfinishedFinalTokenReceivesPrefixSyntax() throws {
        let incremental = try #require(
            EpisodeSearchQueryCompiler.compile(
                "orchard midn",
                mode: .episodes
            )
        )
        let prefix = try #require(
            incremental.primaryChannels.first { $0.kind == .prefix }
        )
        #expect(prefix.matchExpression.contains("\"orchard\""))
        #expect(prefix.matchExpression.contains("\"midn\"*"))
        #expect(!prefix.matchExpression.contains("\"orchard\"*"))

        let completed = try #require(
            EpisodeSearchQueryCompiler.compile(
                "orchard midn ",
                mode: .episodes
            )
        )
        #expect(!completed.primaryChannels.contains { $0.kind == .prefix })
    }

    @Test("Short full-text queries remain in visible fields")
    func shortFullTextQueriesRemainVisibleOnly() throws {
        let short = try #require(
            EpisodeSearchQueryCompiler.compile("ai", mode: .fullText)
        )
        #expect(short.primaryChannels[0].matchExpression.contains("{title podcast_title}"))
        #expect(!short.primaryChannels[0].matchExpression.contains("summary"))

        let topical = try #require(
            EpisodeSearchQueryCompiler.compile("coral", mode: .fullText)
        )
        #expect(topical.primaryChannels[0].matchExpression.contains("summary show_notes"))
    }

    @Test("Relaxation requires all but one term after two tokens")
    func relaxedMinimumShouldMatch() throws {
        let compiled = try #require(
            EpisodeSearchQueryCompiler.compile(
                "drop table episode cache",
                mode: .episodes
            )
        )
        let relaxed = try #require(compiled.relaxedChannel)

        #expect(relaxed.matchExpression.contains("\"drop\" AND \"table\" AND \"episode\""))
        #expect(relaxed.matchExpression.contains(" OR "))
        #expect(!relaxed.matchExpression.contains("\"drop\" OR \"table\" OR"))
    }

    @Test("Empty and very long input stay bounded")
    func emptyAndVeryLongInputStayBounded() throws {
        #expect(
            EpisodeSearchQueryCompiler.compile(
                " \n\t—_!? ",
                mode: .fullText
            ) == nil
        )

        let query = (0..<2_000)
            .map { "token\($0)" }
            .joined(separator: " ")
        let compiled = try #require(
            EpisodeSearchQueryCompiler.compile(query, mode: .fullText)
        )

        #expect(compiled.tokens.count == 12)
        #expect(compiled.tokens.last == "token11")
        #expect(
            compiled.primaryChannels.allSatisfy {
                $0.matchExpression.count < 1_000
            }
        )
    }
}
