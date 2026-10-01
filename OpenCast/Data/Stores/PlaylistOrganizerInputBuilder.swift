import Foundation

/// Turns one show's episodes into the numbered lines a Make a Playlist turn
/// sends, within a token budget measured with the on-device tokenizer. The
/// richest line format that fits wins; when none fits, the last format keeps
/// the newest (or best-matching) episodes that fit. A long show with a
/// specific request sends only its best matches, and suggested groups read
/// only its newest episodes.
nonisolated enum PlaylistOrganizerInputBuilder {
    static let defaultTokenBudget = 20_000
    /// A request prefilters only above this many episodes.
    static let prefilterEpisodeThreshold = 150
    /// Suggested groups read at most this many of the newest episodes. Apple's
    /// model declined or ran past the deadline on longer lists without a request.
    static let suggestionEpisodeLimit = 150
    static let snippetCharacterLimit = 200
    static let boilerplateShare = 0.25
    /// The boilerplate and title-prefix rules need at least this many episodes.
    static let sharedRuleMinimumEpisodeCount = 8
    static let maximumTrimPasses = 6

    private typealias PreparedEpisode = (
        index: Int,
        title: String,
        shortTitle: String,
        snippet: String?,
        date: String?,
        year: String?,
        length: String?
    )

    private typealias Candidates = (
        ranked: [Int],
        kind: PlaylistOrganizerScope.Kind,
        window: EpisodeCandidateWindow?,
        retrievalMilliseconds: Double
    )

    /// Library snapshots + raw summary HTML → builder episodes (HTML cleaned and cut off the main actor).
    @concurrent
    static func episodes(
        from snapshots: [EpisodeListItemSnapshot],
        summaryHTMLByEpisodeID: [String: String]
    ) async -> [PlaylistOrganizerEpisode] {
        snapshots.enumerated().map { offset, snapshot in
            PlaylistOrganizerEpisode(
                index: offset,
                episodeID: snapshot.episodeID,
                publishedAt: snapshot.publishedAt,
                duration: snapshot.duration,
                title: snapshot.title,
                snippet: summaryHTMLByEpisodeID[snapshot.episodeID].flatMap(snippet(fromHTML:))
            )
        }
    }

    /// Date + title + snippet lines for retrieval (boilerplate snippets dropped, show-wide title prefix stripped
    /// from `semanticText`). Synchronous and pure.
    static func metadataLines(for episodes: [PlaylistOrganizerEpisode]) -> [EpisodeMetadataLine] {
        prepare(sortedByIndex(episodes)).map(metadataLine(for:))
    }

    @concurrent
    static func build(
        request: PlaylistOrganizerRequest,
        episodes: [PlaylistOrganizerEpisode],
        options: PlaylistOrganizerInputOptions = PlaylistOrganizerInputOptions(),
        tokenCount: @Sendable (String) async throws -> Int
    ) async throws -> PlaylistOrganizerInput {
        let ordered = sortedByIndex(episodes)
        let prepared = prepare(ordered)
        let preparedByIndex = Dictionary(prepared.map { ($0.index, $0) }) { first, _ in first }
        let episodesByIndex = Dictionary(ordered.map { ($0.index, $0) }) { first, _ in first }
        let show = collapsingWhitespace(request.showTitle)
        let requestText = collapsingWhitespace(request.prompt ?? "")
        let isPrompted = request.mode == .prompted && !requestText.isEmpty
        let candidates = try await chooseCandidates(
            options.candidates,
            prepared: prepared,
            isPrompted: isPrompted,
            requestText: requestText
        )

        func input(rung: PlaylistOrganizerInput.Rung, ranked: [Int], kind: PlaylistOrganizerScope.Kind) -> PlaylistOrganizerInput {
            let indices = ranked.sorted()
            let scope = PlaylistOrganizerScope(kind: kind, sentCount: indices.count, totalCount: ordered.count)
            let lines = indices
                .compactMap { preparedByIndex[$0] }
                .map { line(for: $0, rung: rung) }
                .joined(separator: "\n")
            let prompt = isPrompted
                ? PlaylistOrganizerPrompt.promptedTemplate(
                    show: show,
                    scope: scope.promptText,
                    lines: lines,
                    request: requestText
                )
                : PlaylistOrganizerPrompt.unpromptedTemplate(show: show, scope: scope.promptText, lines: lines)
            var sentEpisodes: [Int: PlaylistOrganizerEpisode] = [:]
            for index in indices {
                sentEpisodes[index] = episodesByIndex[index]
            }
            return PlaylistOrganizerInput(
                prompt: prompt,
                lines: lines,
                scope: scope,
                rung: rung,
                candidateIndices: indices,
                episodesByIndex: sentEpisodes,
                framedTokenCount: 0,
                window: window(candidates.window, keeping: ranked),
                retrievalMilliseconds: candidates.retrievalMilliseconds
            )
        }

        let rungs = options.rungs.isEmpty ? PlaylistOrganizerInput.Rung.allCases : options.rungs
        var ranked = candidates.ranked
        var kind = candidates.kind
        var framedCount = 0
        for rung in rungs {
            try Task.checkCancellation()
            var attempt = input(rung: rung, ranked: ranked, kind: kind)
            attempt.framedTokenCount = try await tokenCount(PlaylistOrganizerPrompt.framed(prompt: attempt.prompt))
            if attempt.framedTokenCount < options.budget {
                return attempt
            }
            framedCount = attempt.framedTokenCount
        }

        let lastRung = rungs.last ?? .compact
        for _ in 0..<maximumTrimPasses {
            try Task.checkCancellation()
            guard ranked.count > 1 else {
                break
            }
            let estimate = Double(ranked.count) * Double(options.budget) / Double(framedCount) * 0.9
            let keep = estimate.isFinite ? Int(min(max(estimate, 1), Double(ranked.count - 1))) : 1
            ranked = Array(ranked.prefix(keep))
            if kind == .all {
                kind = .newest
            }
            var attempt = input(rung: lastRung, ranked: ranked, kind: kind)
            attempt.framedTokenCount = try await tokenCount(PlaylistOrganizerPrompt.framed(prompt: attempt.prompt))
            if attempt.framedTokenCount < options.budget {
                return attempt
            }
            framedCount = attempt.framedTokenCount
        }
        throw TranscriptIntelligenceFailure.contextSizeExceeded(tokenCount: framedCount, contextSize: options.budget)
    }

    // MARK: Candidates

    /// `ranked` is the order a trim keeps from: index order (newest first) for
    /// the whole show, rank order for a retrieved or explicit set.
    private static func chooseCandidates(
        _ choice: PlaylistOrganizerInputOptions.Candidates,
        prepared: [PreparedEpisode],
        isPrompted: Bool,
        requestText: String
    ) async throws -> Candidates {
        let all = prepared.map(\.index)
        let clock = ContinuousClock()
        let started = clock.now
        switch choice {
        case .automatic:
            guard isPrompted else {
                guard prepared.count > suggestionEpisodeLimit else {
                    return (all, .all, nil, 0)
                }
                return (Array(all.prefix(suggestionEpisodeLimit)), .newest, nil, 0)
            }
            guard prepared.count > prefilterEpisodeThreshold else {
                return (all, .all, nil, 0)
            }
            let lines = prepared.map(metadataLine(for:))
            let lexicalIndex = EpisodeMetadataIndex(lines: lines)
            guard lexicalIndex.isInformative(requestText) else {
                return (all, .all, nil, milliseconds(started.duration(to: clock.now)))
            }
            try Task.checkCancellation()
            let language = EpisodeWordVectorEmbedder.language(for: lines)
            let vectorIndex = try await EpisodeWordVectorEmbedder.index(lines: lines, language: language)
            let catalog = PlaylistOrganizerCatalog(
                lines: lines,
                lexicalIndex: lexicalIndex,
                vectorIndex: vectorIndex,
                language: language
            )
            let window = await catalog.window(for: requestText)
            return (window.rankedPositions, .bestMatches, window, milliseconds(started.duration(to: clock.now)))
        case .full:
            return (all, .all, nil, 0)
        case let .lexical(query, limit):
            let lexicalIndex = EpisodeMetadataIndex(lines: prepared.map(metadataLine(for:)))
            let window = EpisodeCandidateRanking.lexicalFirst(
                lexical: lexicalIndex.search(query, limit: limit),
                semantic: [],
                fill: 0,
                limit: max(0, limit)
            )
            return (window.rankedPositions, .bestMatches, window, milliseconds(started.duration(to: clock.now)))
        case .explicit(let list):
            let existing = Set(all)
            var seen = Set<Int>()
            let chosen = list.filter { existing.contains($0) && seen.insert($0).inserted }
            return (chosen, .bestMatches, nil, 0)
        case .newest(let count):
            return (Array(all.prefix(max(0, count))), .newest, nil, 0)
        }
    }

    /// The retrieval window cut to what a trim kept, so it always describes
    /// exactly the lines that were sent.
    private static func window(_ window: EpisodeCandidateWindow?, keeping ranked: [Int]) -> EpisodeCandidateWindow? {
        guard var window, ranked.count < window.rankedPositions.count else {
            return window
        }
        window.rankedPositions = ranked
        window.positions = ranked.sorted()
        window.lexicalCount = min(window.lexicalCount, ranked.count)
        window.fillCount = ranked.count - window.lexicalCount
        return window
    }

    // MARK: Lines

    private static func line(for episode: PreparedEpisode, rung: PlaylistOrganizerInput.Rung) -> String {
        switch rung {
        case .snippets, .titles:
            let line = "\(episode.index). " + [episode.date, episode.length, episode.title]
                .compactMap { $0 }
                .joined(separator: " · ")
            if rung == .snippets, let snippet = episode.snippet {
                return line + " — " + snippet
            }
            return line
        case .compact:
            return "\(episode.index). " + (episode.year.map { "\($0) · " } ?? "") + episode.shortTitle
        }
    }

    /// Publication dates participate in word matching so a year request can
    /// retrieve episodes whose titles never mention that year. The word-vector
    /// text uses prose only and drops the show-wide title prefix.
    private static func metadataLine(for episode: PreparedEpisode) -> EpisodeMetadataLine {
        EpisodeMetadataLine(
            position: episode.index,
            lexicalText: [episode.date, episode.title, episode.snippet].compactMap { $0 }.joined(separator: " "),
            semanticText: episode.snippet.map { episode.shortTitle + ". " + $0 } ?? episode.shortTitle
        )
    }

    // MARK: Preparation

    private static func sortedByIndex(_ episodes: [PlaylistOrganizerEpisode]) -> [PlaylistOrganizerEpisode] {
        var seen = Set<Int>()
        return episodes
            .sorted { $0.index < $1.index }
            .filter { seen.insert($0.index).inserted }
    }

    /// Whitespace collapsed everywhere, so a title holding a newline cannot
    /// start a line of its own; boilerplate snippets dropped; the show-wide
    /// title prefix found; dates read in UTC so every device renders the same
    /// day and year.
    private static func prepare(_ ordered: [PlaylistOrganizerEpisode]) -> [PreparedEpisode] {
        let titles = ordered.map { episode in
            let title = collapsingWhitespace(episode.title)
            return title.isEmpty ? "Episode \(episode.index)" : title
        }
        let snippets = ordered.map { episode -> String? in
            guard let snippet = episode.snippet.map(collapsingWhitespace), !snippet.isEmpty else {
                return nil
            }
            return snippet
        }
        let boilerplate = boilerplateSnippets(snippets)
        let shortTitles = titlesWithoutSharedPrefix(titles)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return ordered.indices.map { offset in
            let episode = ordered[offset]
            let day = episode.publishedAt.flatMap { calendarDay($0, calendar: calendar) }
            let snippet = snippets[offset].flatMap { boilerplate.contains($0) ? nil : $0 }
            return (
                index: episode.index,
                title: titles[offset],
                shortTitle: shortTitles[offset],
                snippet: snippet,
                date: day.map {
                    zeroPadded($0.year, width: 4) + "-" + zeroPadded($0.month, width: 2) + "-"
                        + zeroPadded($0.day, width: 2)
                },
                year: day.map { zeroPadded($0.year, width: 4) },
                length: length(episode.duration)
            )
        }
    }

    /// Snippets repeated across a quarter or more of a show are feed
    /// boilerplate ("Support the show…"): they are never sent or indexed.
    private static func boilerplateSnippets(_ snippets: [String?]) -> Set<String> {
        guard snippets.count >= sharedRuleMinimumEpisodeCount else {
            return []
        }
        var counts: [String: Int] = [:]
        for snippet in snippets.compactMap({ $0 }) {
            counts[snippet, default: 0] += 1
        }
        let threshold = boilerplateShare * Double(snippets.count)
        return Set(counts.filter { Double($0.value) >= threshold }.keys)
    }

    /// Titles without a show-name prefix shared by a quarter or more of the
    /// show ("Show EP 12 — "), with episode numbers ignored when comparing
    /// prefixes. Titles without the winning prefix stay whole.
    private static func titlesWithoutSharedPrefix(_ titles: [String]) -> [String] {
        guard titles.count >= sharedRuleMinimumEpisodeCount else {
            return titles
        }
        // Regex is not Sendable, so both patterns live only for this call.
        let separatedPrefix = #/(.{3,60}?)(\s+[—–-]\s*|\s*[—–]\s*|:\s+|\s+\|\s+)(?=\S)/#
        let episodeNumber = #/\s*#?\s*\d+/#
        let prefixes = titles.map { title -> (template: String, remainder: String)? in
            guard let match = title.prefixMatch(of: separatedPrefix) else {
                return nil
            }
            let template = String(match.output.1)
                .replacing(episodeNumber, with: " #")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (template, String(title[match.range.upperBound...]))
        }
        var counts: [String: Int] = [:]
        for template in prefixes.compactMap({ $0?.template }) {
            counts[template, default: 0] += 1
        }
        let top = counts.min { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        guard let top, Double(top.value) >= boilerplateShare * Double(titles.count) else {
            return titles
        }
        return zip(titles, prefixes).map { title, prefix in
            guard let prefix, prefix.template == top.key else {
                return title
            }
            return prefix.remainder
        }
    }

    // MARK: Formatting

    private static func snippet(fromHTML html: String) -> String? {
        let text = collapsingWhitespace(HTMLPlainText.collapsedText(from: droppingSeveredMarkup(html)))
        guard !text.isEmpty else {
            return nil
        }
        guard text.count > snippetCharacterLimit else {
            return text
        }
        var cut = String(text.prefix(snippetCharacterLimit - 1))
        if let space = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: space) >= snippetCharacterLimit / 2 {
            cut = String(cut[..<space])
        }
        while let last = cut.last, " ,;:.-—".contains(last) {
            cut.removeLast()
        }
        return cut + "…"
    }

    /// The cache hands over markup cut at a fixed length. A tag, style or
    /// script block severed by that cut never closes, so cleaning would
    /// keep its source as text.
    private static func droppingSeveredMarkup(_ html: String) -> String {
        var html = html[...]
        for (open, close) in [("<style", "</style"), ("<script", "</script")] {
            if let block = html.range(of: open, options: [.caseInsensitive, .backwards]),
               html[block.upperBound...].range(of: close, options: .caseInsensitive) == nil {
                html = html[..<block.lowerBound]
            }
        }
        if let tag = html.lastIndex(of: "<"), !html[tag...].contains(">") {
            html = html[..<tag]
        }
        return String(html)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func calendarDay(_ date: Date, calendar: Calendar) -> (year: Int, month: Int, day: Int)? {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }
        return (year, month, day)
    }

    private static func length(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration > 0,
              let minutes = Int(exactly: (duration / 60).rounded())
        else {
            return nil
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return hours > 0 ? "\(hours)h\(zeroPadded(remainder, width: 2))m" : "\(remainder)m"
    }

    private static func zeroPadded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
