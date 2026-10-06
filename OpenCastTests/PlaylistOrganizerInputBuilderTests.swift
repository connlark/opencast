import Foundation
import Synchronization
import Testing
@testable import OpenCast

/// Budgets in the ladder tests sit between the rung counts the digit-heavy
/// counter produces for the fixture, with margins of tens of tokens, so the
/// assertions pin which rung wins rather than an exact count.
@Suite("Playlist organizer input builder")
struct PlaylistOrganizerInputBuilderTests {
    /// 2026-01-02T12:00:00Z.
    private static let january2 = Date(timeIntervalSince1970: 1_767_355_200)
    /// 2026-03-01T12:00:00Z.
    private static let march1 = Date(timeIntervalSince1970: 1_772_366_400)
    private static let day: TimeInterval = 24 * 60 * 60
    private static let week: TimeInterval = 7 * day
    private static let topics = [
        "Harbor Lights",
        "Garden Notes",
        "Night Ferries",
        "Bread and Butter",
        "Quiet Coves",
        "Storm Season",
        "Lantern Makers",
        "Morning Tides",
        "The Old Pier",
        "Winter Roads",
    ]

    @Test("Lines carry the date, length, title and snippet; the compact rung keeps the year and title")
    func lineFormats() async throws {
        let episodes = [
            episode(0, title: "Harbor Lights", publishedAt: Self.january2, duration: 3_720, snippet: "Boats come home at dusk."),
            episode(1, title: "Garden Notes", publishedAt: Self.january2 - Self.week, duration: 2_700),
            episode(2, title: "Night Ferries", publishedAt: nil, duration: 3_580, snippet: "Crossing the strait."),
            episode(3, title: "Quiet Coves", publishedAt: Self.january2 - 3 * Self.week, duration: nil, snippet: "Small harbors."),
        ]

        let snippets = try await build(episodes, rungs: [.snippets])
        #expect(
            snippets.lines.split(separator: "\n").map(String.init) == [
                "0. 2026-01-02 · 1h02m · Harbor Lights — Boats come home at dusk.",
                "1. 2025-12-26 · 45m · Garden Notes",
                "2. 1h00m · Night Ferries — Crossing the strait.",
                "3. 2025-12-12 · Quiet Coves — Small harbors.",
            ]
        )
        #expect(snippets.rung == .snippets)
        #expect(snippets.candidateIndices == [0, 1, 2, 3])
        #expect(snippets.episodesByIndex.keys.sorted() == [0, 1, 2, 3])
        #expect(snippets.scope == PlaylistOrganizerScope(kind: .all, sentCount: 4, totalCount: 4))
        #expect(snippets.window == nil)
        #expect(snippets.retrievalMilliseconds == 0)
        #expect(
            snippets.prompt == PlaylistOrganizerPrompt.promptedTemplate(
                show: "Example Show",
                scope: "all 4",
                lines: snippets.lines,
                request: "harbor stories"
            )
        )
        #expect(snippets.framedTokenCount == Self.digitHeavyCount(PlaylistOrganizerPrompt.framed(prompt: snippets.prompt)))

        let titles = try await build(episodes, rungs: [.titles])
        #expect(
            titles.lines.split(separator: "\n").map(String.init) == [
                "0. 2026-01-02 · 1h02m · Harbor Lights",
                "1. 2025-12-26 · 45m · Garden Notes",
                "2. 1h00m · Night Ferries",
                "3. 2025-12-12 · Quiet Coves",
            ]
        )

        let compact = try await build(episodes, rungs: [.compact])
        #expect(
            compact.lines.split(separator: "\n").map(String.init) == [
                "0. 2026 · Harbor Lights",
                "1. 2025 · Garden Notes",
                "2. Night Ferries",
                "3. 2025 · Quiet Coves",
            ]
        )
        #expect(compact.rung == .compact)
    }

    @Test("The ladder takes the first rung under the budget as the given counter measures it")
    func ladderPicksFirstRungUnderBudget() async throws {
        let episodes = ladderEpisodes()

        let roomy = try await build(episodes)
        #expect(roomy.rung == .snippets)
        #expect(roomy.candidateIndices == Array(0..<10))

        // Digit-heavy counts for this fixture: snippets 830, titles 497, compact 414.
        let titles = try await build(episodes, budget: 700)
        #expect(titles.rung == .titles)
        #expect(titles.candidateIndices == Array(0..<10))
        #expect(titles.scope.kind == .all)
        #expect(titles.framedTokenCount < 700)
        #expect(titles.lines.split(separator: "\n").first == "0. 2026-03-01 · 30m · Harbor Lights")

        let compact = try await build(episodes, budget: 450)
        #expect(compact.rung == .compact)
        #expect(compact.candidateIndices == Array(0..<10))
        #expect(compact.framedTokenCount < 450)

        // A quarter-character counter would have sent the snippets at 700.
        let quarter = try await build(episodes, budget: 700, tokenCount: { $0.count / 4 })
        #expect(quarter.rung == .snippets)
    }

    @Test("Forcing a single rung skips the ladder")
    func singleRungIsForced() async throws {
        let input = try await build(ladderEpisodes(), rungs: [.compact])

        #expect(input.rung == .compact)
        #expect(input.lines.split(separator: "\n").first == "0. 2026 · Harbor Lights")
        #expect(input.candidateIndices == Array(0..<10))
    }

    @Test("A long show keeps the newest episodes that fit, and the scope says so")
    func newestThatFitCut() async throws {
        let episodes = roundupEpisodes(count: 60)
        let budget = 600

        let input = try await build(episodes, mode: .unprompted, budget: budget)

        let kept = input.candidateIndices.count
        #expect(input.scope.kind == .newest)
        #expect(input.scope.sentCount == kept)
        #expect(input.scope.totalCount == 60)
        // The largest newest prefix that fits is 19 lines; the proportional cut lands at or under it.
        #expect((10...19).contains(kept))
        #expect(input.candidateIndices == Array(0..<kept))
        #expect(input.rung == .compact)
        #expect(input.scope.promptText == "the newest \(kept) of 60")
        #expect(input.prompt.contains("Episodes (the newest \(kept) of 60), newest first:"))
        #expect(input.framedTokenCount < budget)
        #expect(input.framedTokenCount == Self.digitHeavyCount(PlaylistOrganizerPrompt.framed(prompt: input.prompt)))
    }

    @Test("A ranked candidate list that does not fit keeps its best-ranked entries, sent in index order")
    func rankedCutKeepsRankOrderPrefix() async throws {
        let order = [9, 3, 7, 1, 5, 30, 22, 41, 18, 50, 12, 2]

        let input = try await build(
            roundupEpisodes(count: 60),
            mode: .unprompted,
            candidates: .explicit(order),
            budget: 420
        )

        let kept = input.candidateIndices.count
        #expect((1...8).contains(kept))
        #expect(input.candidateIndices == Array(order.prefix(kept)).sorted())
        #expect(input.scope == PlaylistOrganizerScope(kind: .bestMatches, sentCount: kept, totalCount: 60))
        #expect(input.rung == .compact)
        #expect(input.framedTokenCount < 420)
    }

    @Test("A list that cannot fit at all throws context-size-exceeded against the budget")
    func unfittableListThrows() async throws {
        do {
            _ = try await build(ladderEpisodes(), budget: 10)
            Issue.record("The builder returned an input under a 10-token budget.")
        } catch let failure as TranscriptIntelligenceFailure {
            guard case .contextSizeExceeded(_, let contextSize) = failure else {
                Issue.record("Expected context-size-exceeded, got \(failure).")
                return
            }
            #expect(contextSize == 10)
        }
    }

    @Test("Explicit candidates keep the existing indices in index order; newest candidates take the first n")
    func explicitAndNewestCandidates() async throws {
        let episodes = ladderEpisodes()

        let explicit = try await build(episodes, candidates: .explicit([7, 2, 99]))
        #expect(explicit.candidateIndices == [2, 7])
        #expect(explicit.scope == PlaylistOrganizerScope(kind: .bestMatches, sentCount: 2, totalCount: 10))
        #expect(explicit.prompt.contains("Episodes (the 2 of 10 that best match the request), newest first:"))
        let explicitLines = explicit.lines.split(separator: "\n")
        #expect(explicitLines.count == 2)
        #expect(explicitLines.first?.hasPrefix("2. ") == true)
        #expect(explicitLines.last?.hasPrefix("7. ") == true)
        #expect(explicit.episodesByIndex.keys.sorted() == [2, 7])

        let newest = try await build(episodes, candidates: .newest(3))
        #expect(newest.candidateIndices == [0, 1, 2])
        #expect(newest.scope == PlaylistOrganizerScope(kind: .newest, sentCount: 3, totalCount: 10))
        #expect(newest.scope.promptText == "the newest 3 of 10")
        #expect(newest.lines.split(separator: "\n").count == 3)
    }

    @Test("On a long show a rare request word prefilters to its matches, sent with their own indices in index order")
    func prefilteredLinesKeepOriginalIndices() async throws {
        let lighthouseTitles = [
            3: "Keeping the Lighthouse",
            47: "Lighthouse Lenses",
            90: "A Lighthouse in Fog",
            151: "Lighthouse Keepers and Their Logs",
            188: "The Last Lighthouse",
        ]
        let episodes = roundupEpisodes(count: 200, replacingTitles: lighthouseTitles)

        let input = try await build(episodes, prompt: "Make me a playlist about lighthouses")

        let hits = lighthouseTitles.keys.sorted()
        let window = try #require(input.window)
        #expect(input.scope.kind == .bestMatches)
        #expect(input.scope.totalCount == 200)
        #expect(input.scope.sentCount == input.candidateIndices.count)
        #expect(input.candidateIndices == input.candidateIndices.sorted())
        #expect(Set(input.candidateIndices).count == input.candidateIndices.count)
        #expect(Set(hits).isSubset(of: input.candidateIndices))
        #expect(window.lexicalCount == hits.count)
        #expect(window.fillCount <= 30)
        #expect(input.candidateIndices.count == window.lexicalCount + window.fillCount)
        #expect(window.positions == input.candidateIndices)
        #expect(Array(window.rankedPositions.prefix(hits.count)).sorted() == hits)
        #expect(input.episodesByIndex.keys.sorted() == input.candidateIndices)
        #expect(input.prompt.contains("Episodes (\(input.scope.promptText)), newest first:"))

        let lines = input.lines.split(separator: "\n").map(String.init)
        #expect(lines.count == input.candidateIndices.count)
        for (line, index) in zip(lines, input.candidateIndices) {
            #expect(line.hasPrefix("\(index). "), "line for index \(index)")
        }
        for index in hits {
            let line = lines.first { $0.hasPrefix("\(index). ") }
            #expect(line?.hasSuffix(lighthouseTitles[index] ?? "") == true, "line for index \(index)")
        }
    }

    @Test("Year requests retrieve all dated matches even when only unrelated titles mention the year")
    func publicationYearsParticipateInRetrieval() async throws {
        let january2020 = Date(timeIntervalSince1970: 1_577_836_800)
        let datedMatches = Array(180..<200)
        let episodes = (0..<200).map { index in
            episode(
                index,
                title: index == 0 ? "Looking back at 2020" : "Weekly Roundup Number \(200 - index)",
                publishedAt: index >= 180 ? january2020 + Double(199 - index) * Self.week : Self.march1,
                duration: 2_400
            )
        }
        let lines = PlaylistOrganizerInputBuilder.metadataLines(for: episodes)
        let index = EpisodeMetadataIndex(lines: lines)
        #expect(index.informativeMatches("episodes from 2020").map(\.position).sorted() == [0] + datedMatches)
        #expect(!lines[180].semanticText.contains("2020"))

        let input = try await build(episodes, prompt: "episodes from 2020")
        #expect(input.scope.kind == .bestMatches)
        #expect(input.window?.lexicalCount == 21)
        #expect(Set(datedMatches).isSubset(of: input.candidateIndices))
        #expect(datedMatches.allSatisfy { input.episodesByIndex[$0] != nil })
    }

    @Test("A request whose words hit more than half the lines, or a request on a short show, sends the whole show")
    func uninformativeRequestSendsEverything() async throws {
        let episodes = roundupEpisodes(count: 200, replacingTitles: [3: "Keeping the Lighthouse"])

        let common = try await build(episodes, prompt: "weekly roundup")
        #expect(common.scope == PlaylistOrganizerScope(kind: .all, sentCount: 200, totalCount: 200))
        #expect(common.candidateIndices == Array(0..<200))
        #expect(common.window == nil)
        #expect(common.lines.split(separator: "\n").count == 200)

        let short = try await build(Array(episodes.prefix(150)), prompt: "lighthouse")
        #expect(short.scope == PlaylistOrganizerScope(kind: .all, sentCount: 150, totalCount: 150))
        #expect(short.window == nil)
    }

    @Test("Suggestions on a long show read only the newest 150 episodes, and the scope says so")
    func suggestionsReadTheNewestEpisodes() async throws {
        let episodes = roundupEpisodes(count: 200, replacingTitles: [3: "Keeping the Lighthouse"])

        let capped = try await build(episodes, mode: .unprompted)
        #expect(PlaylistOrganizerInputBuilder.suggestionEpisodeLimit == 150)
        #expect(capped.scope == PlaylistOrganizerScope(kind: .newest, sentCount: 150, totalCount: 200))
        #expect(capped.candidateIndices == Array(0..<150))
        #expect(capped.episodesByIndex.keys.sorted() == Array(0..<150))
        #expect(capped.window == nil)
        #expect(capped.lines.split(separator: "\n").count == 150)
        #expect(capped.prompt.contains("Episodes (the newest 150 of 200), newest first:"))

        // A blank request is a suggestion too.
        let blank = try await build(episodes, prompt: "  ")
        #expect(blank.scope == capped.scope)
        #expect(blank.prompt == capped.prompt)

        let atLimit = try await build(Array(episodes.prefix(150)), mode: .unprompted)
        #expect(atLimit.scope == PlaylistOrganizerScope(kind: .all, sentCount: 150, totalCount: 150))

        // A capped list that still does not fit keeps cutting from the newest end.
        let tight = try await build(episodes, mode: .unprompted, budget: 600)
        let kept = tight.candidateIndices.count
        #expect(tight.scope == PlaylistOrganizerScope(kind: .newest, sentCount: kept, totalCount: 200))
        #expect((1..<150).contains(kept))
        #expect(tight.candidateIndices == Array(0..<kept))
        #expect(tight.framedTokenCount < 600)

        // The forced whole-show choice is not capped.
        let full = try await build(episodes, mode: .unprompted, candidates: .full)
        #expect(full.scope == PlaylistOrganizerScope(kind: .all, sentCount: 200, totalCount: 200))
    }

    @Test("A shared show-name prefix is stripped from compact lines and semantic text; a show without one is left alone")
    func prefixVote() async throws {
        let prefixed = Self.topics.enumerated().map { index, topic in
            episode(
                index,
                title: "Show Name EP \(12 - index) — \(topic)",
                publishedAt: Self.march1 - Double(index) * Self.day,
                duration: 1_800,
                snippet: index == 0 ? "Boats at dusk." : nil
            )
        }

        let stripped = try await build(prefixed, rungs: [.compact])
        #expect(
            stripped.lines.split(separator: "\n").map(String.init)
                == Self.topics.enumerated().map { "\($0.offset). 2026 · \($0.element)" }
        )
        let strippedLines = PlaylistOrganizerInputBuilder.metadataLines(for: prefixed)
        #expect(strippedLines.map(\.position) == Array(0..<10))
        #expect(strippedLines.first?.semanticText == "Harbor Lights. Boats at dusk.")
        #expect(strippedLines.first?.lexicalText == "2026-03-01 Show Name EP 12 — Harbor Lights Boats at dusk.")
        #expect(strippedLines.dropFirst().map(\.semanticText) == Array(Self.topics.dropFirst()))
        #expect(
            strippedLines.dropFirst().map { String($0.lexicalText.dropFirst(11)) }
                == prefixed.dropFirst().map(\.title)
        )

        let unsharedTitles = [
            "Alpha: Harbor Lights",
            "Beta: Garden Notes",
            "Show Name EP 2 — Night Ferries",
            "Show Name EP 1 — Bread and Butter",
        ] + Self.topics.dropFirst(4)
        let unshared = unsharedTitles.enumerated().map { index, title in
            episode(index, title: title, publishedAt: Self.march1 - Double(index) * Self.day, duration: 1_800)
        }
        let kept = try await build(unshared, rungs: [.compact])
        #expect(
            kept.lines.split(separator: "\n").map(String.init)
                == unsharedTitles.enumerated().map { "\($0.offset). 2026 · \($0.element)" }
        )
        #expect(PlaylistOrganizerInputBuilder.metadataLines(for: unshared).map(\.semanticText) == unsharedTitles)

        let fewTitles = Array(prefixed.prefix(4))
        let few = try await build(fewTitles, rungs: [.compact])
        #expect(few.lines.split(separator: "\n").first == "0. 2026 · Show Name EP 12 — Harbor Lights")
    }

    @Test("A newline inside a title or snippet cannot forge a line, and an empty title gets a placeholder")
    func newlineCannotForgeLine() async throws {
        let episodes = [
            episode(
                0,
                title: "Real Title\n12. Forged Line",
                publishedAt: Self.january2,
                duration: 1_800,
                snippet: "First line\n\n13. Another forged line"
            ),
            episode(1, title: "", publishedAt: Self.january2, duration: 1_800),
        ]

        let input = try await build(episodes, rungs: [.snippets])

        #expect(
            input.lines.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) == [
                "0. 2026-01-02 · 30m · Real Title 12. Forged Line — First line 13. Another forged line",
                "1. 2026-01-02 · 30m · Episode 1",
            ]
        )
    }

    @Test("A snippet most of a long show shares is dropped; a short show keeps it")
    func boilerplateSnippetsDropped() async throws {
        let shared = "Support the show at example dot com."
        let episodes = Self.topics.enumerated().map { index, topic in
            episode(
                index,
                title: topic,
                publishedAt: Self.march1 - Double(index) * Self.week,
                duration: 1_800,
                snippet: [1, 4, 7].contains(index) ? shared : "Notes on \(topic.lowercased())."
            )
        }

        let input = try await build(episodes, rungs: [.snippets])

        let lines = input.lines.split(separator: "\n").map(String.init)
        #expect(lines.count == 10)
        #expect(!input.lines.contains(shared))
        #expect(lines[1] == "1. 2026-02-22 · 30m · Garden Notes")
        #expect(lines[0] == "0. 2026-03-01 · 30m · Harbor Lights — Notes on harbor lights.")
        let metadata = PlaylistOrganizerInputBuilder.metadataLines(for: episodes)
        #expect(metadata.allSatisfy { !$0.lexicalText.contains(shared) && !$0.semanticText.contains(shared) })
        #expect(metadata[0].lexicalText == "2026-03-01 Harbor Lights Notes on harbor lights.")

        let shortShow = Self.topics.prefix(4).enumerated().map { index, topic in
            episode(index, title: topic, publishedAt: Self.march1 - Double(index) * Self.week, duration: 1_800, snippet: shared)
        }
        let short = try await build(shortShow, rungs: [.snippets])
        #expect(short.lines.split(separator: "\n").map(String.init)[1] == "1. 2026-02-22 · 30m · Garden Notes — \(shared)")
    }

    @Test("NaN, infinite, zero, negative and missing durations render without a length")
    func unusableDurationsOmitLength() async throws {
        let durations: [TimeInterval?] = [.nan, .infinity, 0, -60, nil, 60]
        let episodes = durations.enumerated().map { index, duration in
            episode(index, title: "Topic \(index)", publishedAt: Self.january2, duration: duration)
        }

        let input = try await build(episodes, rungs: [.titles])

        #expect(
            input.lines.split(separator: "\n").map(String.init) == [
                "0. 2026-01-02 · Topic 0",
                "1. 2026-01-02 · Topic 1",
                "2. 2026-01-02 · Topic 2",
                "3. 2026-01-02 · Topic 3",
                "4. 2026-01-02 · Topic 4",
                "5. 2026-01-02 · 1m · Topic 5",
            ]
        )
    }

    @Test("Dates and years are rendered in UTC")
    func datesAreUTC() async throws {
        // 2025-12-31T23:30:00-05:00, which is already 2026 in UTC.
        let newYear = Date(timeIntervalSince1970: 1_767_241_800)
        let episodes = [episode(0, title: "New Year Special", publishedAt: newYear, duration: 1_800)]

        let titles = try await build(episodes, rungs: [.titles])
        #expect(titles.lines == "0. 2026-01-01 · 30m · New Year Special")

        let compact = try await build(episodes, rungs: [.compact])
        #expect(compact.lines == "0. 2026 · New Year Special")
    }

    @Test("Snapshots become episodes with cleaned snippets cut at a word near 200 characters")
    func snippetCutRule() async {
        let listSummary = (1...40).map { "item\($0)," }.joined(separator: " ")
        let summaries = [
            "list": listSummary,
            "no-space": String(repeating: "x", count: 50) + " " + String(repeating: "y", count: 200),
            "space": String(repeating: "x", count: 150) + " " + String(repeating: "y", count: 100),
            "punctuation": String(repeating: "a", count: 150) + " end. — " + String(repeating: "b", count: 60),
            "exact": String(repeating: "w", count: 200),
            "html": "<p>Boats come <b>home</b>\n at   dusk.</p>",
            "blank": "<p> </p>",
            "severed-tag": "<p>Boats come home.</p> <a href=\"https://example.com/a/very/long/li",
            "severed-style": "<p>Boats leave.</p><STYLE>p { color: red; } .note { margin",
        ]
        let ids = [
            "list", "no-space", "space", "punctuation", "exact", "html", "blank", "missing",
            "severed-tag", "severed-style",
        ]
        let snapshots = ids.enumerated().map { offset, id in
            EpisodeListItemSnapshot.fixture(
                episodeID: id,
                title: "Title \(id)",
                publishedAt: Self.january2 - Double(offset) * Self.week,
                duration: 1_200,
                audioURL: "https://example.com/\(id).mp3",
                guid: id
            )
        }

        let episodes = await PlaylistOrganizerInputBuilder.episodes(from: snapshots, summaryHTMLByEpisodeID: summaries)

        #expect(episodes.map(\.index) == Array(0..<10))
        #expect(episodes.map(\.episodeID) == ids)
        #expect(episodes.map(\.title) == ids.map { "Title \($0)" })
        #expect(episodes.map(\.publishedAt) == snapshots.map(\.publishedAt))
        #expect(episodes.map(\.duration) == snapshots.map(\.duration))
        let snippets = episodes.map(\.snippet)
        #expect(
            snippets[0] == "item1, item2, item3, item4, item5, item6, item7, item8, item9, item10, item11, item12, "
                + "item13, item14, item15, item16, item17, item18, item19, item20, item21, item22, item23, item24, "
                + "item25, item26…"
        )
        #expect(snippets[1] == String(repeating: "x", count: 50) + " " + String(repeating: "y", count: 148) + "…")
        #expect(snippets[2] == String(repeating: "x", count: 150) + "…")
        #expect(snippets[3] == String(repeating: "a", count: 150) + " end…")
        #expect(snippets[4] == String(repeating: "w", count: 200))
        #expect(snippets[5] == "Boats come home at dusk.")
        #expect(snippets[6] == nil)
        #expect(snippets[7] == nil)
        #expect(snippets[8] == "Boats come home.")
        #expect(snippets[9] == "Boats leave.")
        #expect(snippets.allSatisfy { ($0?.count ?? 0) <= 200 })
    }

    // MARK: - Line numbers and the simpler answer

    @Test("Gapped line numbers rise by 1 to 3 from a seed, map back to the episode indices, and change nothing else")
    func gappedLineNumbersIncreaseWithSmallGaps() async throws {
        let episodes = ladderEpisodes()
        let indexed = try await build(episodes)
        let gapped = try await build(episodes, lineNumbers: .gapped(seed: 42))
        let again = try await build(episodes, lineNumbers: .gapped(seed: 42))

        let numbered = gapped.lines.split(separator: "\n").map { Self.splitLineNumber(String($0)) }
        let numbers = numbered.compactMap { $0.number }
        #expect(numbers.count == 10)
        #expect((1...9).contains(numbers.first ?? 0))
        #expect(zip(numbers, numbers.dropFirst()).allSatisfy { (1...3).contains($1 - $0) })
        // Only the numbers differ from the index-numbered lines.
        #expect(numbered.map { $0.rest } == indexed.lines.split(separator: "\n").map { Self.splitLineNumber(String($0)).rest })
        #expect(gapped.indexByLineNumber == Dictionary(zip(numbers, gapped.candidateIndices)) { first, _ in first })
        for (number, index) in zip(numbers, gapped.candidateIndices) {
            #expect(gapped.episodeIndex(forLineNumber: number) == index, "line \(number)")
        }
        #expect(gapped.episodeIndex(forLineNumber: 0) == nil)
        #expect(gapped.episodeIndex(forLineNumber: (numbers.last ?? 0) + 1) == nil)

        #expect(again.lines == gapped.lines)
        #expect(again.indexByLineNumber == gapped.indexByLineNumber)
        #expect(gapped.candidateIndices == indexed.candidateIndices)
        #expect(gapped.scope == indexed.scope)
        #expect(gapped.episodesByIndex == indexed.episodesByIndex)
        #expect(gapped.rung == indexed.rung)
        #expect(
            gapped.prompt == PlaylistOrganizerPrompt.promptedTemplate(
                show: "Example Show",
                scope: "all 10",
                lines: gapped.lines,
                request: "harbor stories"
            )
        )
        #expect(gapped.framedTokenCount == Self.digitHeavyCount(PlaylistOrganizerPrompt.framed(prompt: gapped.prompt)))

        // The numbers are fixed before the ladder, so every rung carries the same ones.
        let compact = try await build(episodes, rungs: [.compact], lineNumbers: .gapped(seed: 42))
        #expect(compact.indexByLineNumber == gapped.indexByLineNumber)

        // An index build starts each line with its index and maps n to n.
        #expect(indexed.indexByLineNumber.isEmpty)
        #expect(indexed.lines.split(separator: "\n").compactMap { Self.splitLineNumber(String($0)).number } == Array(0..<10))
        #expect(indexed.episodeIndex(forLineNumber: 0) == 0)
        #expect(indexed.episodeIndex(forLineNumber: 7) == 7)

        // A random seed keeps the same shape.
        let unseeded = try await build(episodes, lineNumbers: .gapped(seed: nil))
        let unseededNumbers = unseeded.lines.split(separator: "\n").compactMap { Self.splitLineNumber(String($0)).number }
        #expect(unseededNumbers.count == 10)
        #expect((1...9).contains(unseededNumbers.first ?? 0))
        #expect(zip(unseededNumbers, unseededNumbers.dropFirst()).allSatisfy { (1...3).contains($1 - $0) })
        #expect(unseeded.indexByLineNumber == Dictionary(zip(unseededNumbers, unseeded.candidateIndices)) { first, _ in first })
    }

    @Test("Gapped numbers cover only the candidates, so a prefiltered list keeps its episodes with small numbers and gaps")
    func gappedLineNumbersCoverTheCandidates() async throws {
        let lighthouseTitles = [
            3: "Keeping the Lighthouse",
            47: "Lighthouse Lenses",
            90: "A Lighthouse in Fog",
            151: "Lighthouse Keepers and Their Logs",
            188: "The Last Lighthouse",
        ]
        let episodes = roundupEpisodes(count: 200, replacingTitles: lighthouseTitles)
        let request = "Make me a playlist about lighthouses"

        let indexed = try await build(episodes, prompt: request)
        let gapped = try await build(episodes, prompt: request, lineNumbers: .gapped(seed: 42))

        #expect(gapped.scope.kind == .bestMatches)
        #expect(gapped.candidateIndices == indexed.candidateIndices)
        #expect(gapped.scope == indexed.scope)
        #expect(gapped.window == indexed.window)
        let candidates = PlaylistOrganizerLineNumbers.gapped(for: indexed.candidateIndices, seed: 42)
        let numbers = gapped.lines.split(separator: "\n").compactMap { Self.splitLineNumber(String($0)).number }
        #expect(numbers.count == gapped.candidateIndices.count)
        #expect(numbers == gapped.candidateIndices.compactMap { candidates[$0] })
        #expect(zip(numbers, numbers.dropFirst()).allSatisfy { (1...3).contains($1 - $0) })
        #expect((numbers.last ?? 0) <= 9 + 3 * (numbers.count - 1))
        #expect(gapped.indexByLineNumber.count == gapped.candidateIndices.count)
        #expect(Set(gapped.indexByLineNumber.values) == Set(gapped.candidateIndices))
        for (number, index) in zip(numbers, gapped.candidateIndices) {
            #expect(gapped.episodeIndex(forLineNumber: number) == index, "line \(number)")
        }
    }

    @Test("The simpler answer's input carries its own instructions, counts them, and sends the same lines")
    func simplerAnswerCountsItsOwnInstructions() async throws {
        let recorder = CountedTexts()
        let simpler = try await build(ladderEpisodes(), answerStyle: .indicesOnly) { text in
            recorder.record(text)
            return PlaylistOrganizerInputBuilderTests.digitHeavyCount(text)
        }
        let standard = try await build(ladderEpisodes())

        let instructions = PlaylistOrganizerPrompt.simplerAnswerInstructions
        let framed = PlaylistOrganizerPrompt.framed(instructions: instructions, prompt: simpler.prompt)
        #expect(simpler.answerStyle == .indicesOnly)
        #expect(simpler.instructions == instructions)
        #expect(!recorder.texts.isEmpty)
        #expect(recorder.texts.last == framed)
        #expect(recorder.texts.allSatisfy { $0.hasPrefix(instructions + "\n\n") })
        #expect(simpler.framedTokenCount == Self.digitHeavyCount(framed))
        #expect(simpler.prompt == standard.prompt)
        #expect(simpler.candidateIndices == standard.candidateIndices)
        #expect(simpler.rung == standard.rung)

        #expect(standard.answerStyle == .standard)
        #expect(standard.instructions == PlaylistOrganizerPrompt.instructions)
        #expect(standard.framedTokenCount == Self.digitHeavyCount(PlaylistOrganizerPrompt.framed(prompt: standard.prompt)))
    }

    @Test("Seeded line numbers are deterministic, start at 1 to 9 and rise by 1 to 3 in index order")
    func gappedLineNumbersAreDeterministicPerSeed() {
        let indices = [5, 0, 3, 9, 1, 12]
        for seed in [0, 1, 7, 42, UInt64.max] {
            let numbers = PlaylistOrganizerLineNumbers.gapped(for: indices, seed: seed)
            #expect(numbers == PlaylistOrganizerLineNumbers.gapped(for: indices, seed: seed), "seed \(seed)")
            #expect(numbers == PlaylistOrganizerLineNumbers.gapped(for: indices.sorted(), seed: seed), "seed \(seed)")
            #expect(numbers.keys.sorted() == indices.sorted(), "seed \(seed)")
            let ascending = indices.sorted().compactMap { numbers[$0] }
            #expect(ascending.count == indices.count, "seed \(seed)")
            #expect((1...9).contains(ascending.first ?? 0), "seed \(seed)")
            #expect(zip(ascending, ascending.dropFirst()).allSatisfy { (1...3).contains($1 - $0) }, "seed \(seed)")
        }
        let show = Array(0..<100)
        #expect(PlaylistOrganizerLineNumbers.gapped(for: show, seed: 1) != PlaylistOrganizerLineNumbers.gapped(for: show, seed: 2))
        #expect(PlaylistOrganizerLineNumbers.gapped(for: [], seed: 7).isEmpty)
    }

    // MARK: - Fixtures

    /// A sent line's leading number and the text after its ". ".
    private static func splitLineNumber(_ line: String) -> (number: Int?, rest: String) {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        let remainder = line.dropFirst(digits.count)
        guard !digits.isEmpty, remainder.hasPrefix(". ") else {
            return (nil, line)
        }
        return (Int(digits), String(remainder.dropFirst(2)))
    }

    /// One token per ASCII digit plus one per four other characters: dates
    /// and indices cost far more than prose, as they do for Apple's model.
    private static func digitHeavyCount(_ text: String) -> Int {
        let digits = text.unicodeScalars.count { $0.value >= 48 && $0.value <= 57 }
        return digits + (text.count - digits) / 4
    }

    private func build(
        _ episodes: [PlaylistOrganizerEpisode],
        mode: PlaylistOrganizerMode = .prompted,
        prompt: String = "harbor stories",
        candidates: PlaylistOrganizerInputOptions.Candidates = .automatic,
        rungs: [PlaylistOrganizerInput.Rung] = PlaylistOrganizerInput.Rung.allCases,
        budget: Int = PlaylistOrganizerInputBuilder.defaultTokenBudget,
        lineNumbers: PlaylistOrganizerInputOptions.LineNumbers = .index,
        answerStyle: PlaylistOrganizerAnswerStyle = .standard,
        tokenCount: @escaping @Sendable (String) -> Int = { PlaylistOrganizerInputBuilderTests.digitHeavyCount($0) }
    ) async throws -> PlaylistOrganizerInput {
        var options = PlaylistOrganizerInputOptions()
        options.candidates = candidates
        options.rungs = rungs
        options.budget = budget
        options.lineNumbers = lineNumbers
        return try await PlaylistOrganizerInputBuilder.build(
            request: PlaylistOrganizerRequest(
                podcastID: "https://example.com/feed.xml",
                showTitle: "Example Show",
                mode: mode,
                prompt: mode == .prompted ? prompt : nil,
                answerStyle: answerStyle
            ),
            episodes: episodes,
            options: options,
            tokenCount: { text in tokenCount(text) }
        )
    }

    private func episode(
        _ index: Int,
        title: String,
        publishedAt: Date?,
        duration: TimeInterval?,
        snippet: String? = nil
    ) -> PlaylistOrganizerEpisode {
        PlaylistOrganizerEpisode(
            index: index,
            episodeID: "episode-\(index)",
            publishedAt: publishedAt,
            duration: duration,
            title: title,
            snippet: snippet
        )
    }

    /// Ten dated episodes whose snippets are full of digits.
    private func ladderEpisodes() -> [PlaylistOrganizerEpisode] {
        Self.topics.enumerated().map { index, topic in
            episode(
                index,
                title: topic,
                publishedAt: Self.march1 - Double(index) * Self.week,
                duration: 1_800 + 600 * Double(index),
                snippet: "Episode \(index + 1) of the season: listeners call in from 10 towns with 25 questions "
                    + "about \(topic.lowercased()) and 3 follow-ups."
            )
        }
    }

    private func roundupEpisodes(count: Int, replacingTitles titles: [Int: String] = [:]) -> [PlaylistOrganizerEpisode] {
        (0..<count).map { index in
            episode(
                index,
                title: titles[index] ?? "Weekly Roundup Number \(count - index)",
                publishedAt: Self.march1 - Double(index) * Self.week,
                duration: 2_400
            )
        }
    }
}

/// Every text the builder asked the token counter to measure, in order.
private final class CountedTexts: Sendable {
    private let storage = Mutex<[String]>([])

    var texts: [String] {
        storage.withLock { $0 }
    }

    func record(_ text: String) {
        storage.withLock { $0.append(text) }
    }
}
