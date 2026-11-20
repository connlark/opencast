import Foundation

public enum ShowNotesChaptersParser {
    public static let minimumChapterCount = 3

    private static let bullet = #"(?:\p{Pd}|[•*]|\d{1,3}\.)"#

    private static let rangeJoin = #"\s*+[)\]]?\s*+(?:\p{Pd}++|(?i:to))\s*+[(\[]?\s*+"#

    /// Only digits identify a range's end: `ShowNotesTimestamp.pattern` refuses a time followed
    /// by `:`, so it would miss the end of `0:00 - 1:00: Intro`. A last range may end at the
    /// word END, unless the title is all capitals (`END OF AN ERA`) or, in lower case, nothing sets it off.
    private static let rangeEnd = #"(?:(?:\d{1,2}:)?[0-5]?\d:[0-5]\d(?!\d|:\d|\.\d|\s*+(?i:[ap]\.?m)\b)"#
        + #"|END\b(?!\P{Ll}*+$)|(?i:end)(?=\s*+[)\]:|]|\s++\p{Pd}))"#

    /// Whitespace runs are possessive so a long line cannot backtrack through them. Given back
    /// one character, the separator run would turn a line like `00:00 -` into a chapter `-`.
    private static let entryLine = try! NSRegularExpression(
        pattern: #"^\s*+(?:"# + bullet + #"\s++)?(?:[(\[]\s*+)?"# + ShowNotesTimestamp.pattern
            + "(?:" + rangeJoin + rangeEnd + ")?(?!" + rangeJoin + #"\d{1,2}:\d{2})"#
            + #"[\s\p{Pd}:|)\]]++(?<title>.+)"#
    )

    private static let bracketedTimestamp = try! NSRegularExpression(
        pattern: #"[(\[]\s*+"# + ShowNotesTimestamp.pattern + #"\s*+[)\]]"#
    )

    /// A sentence end before a list's first title. The period needs three lowercase letters
    /// before it, so `vs.` and `Dr.` keep the words in front of them.
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"(?<=\p{Ll}{3}|[\p{Nd}\p{Pe}\p{Pf}"])[.!?]["\p{Pe}\p{Pf}]*+\s++"#)

    /// `structuredText` writes `<li>` as `- `, so a lone bullet line can sit between entries.
    /// Possessive, or a long run of spaces before a letter takes quadratic time to reject.
    private static let blankLine = try! NSRegularExpression(pattern: #"^\s*+"# + bullet + #"?\s*+$"#)

    private typealias Entry = (start: Int, title: String)

    /// `text` is show-notes plain text with one entry per line (`HTMLPlainText.structuredText`).
    public static func chapters(in text: String, duration: TimeInterval?) -> [EpisodeChapter] {
        chapters(in: CollectionOfOne(text), duration: duration)
    }

    /// `texts` are in order of preference. A timestamp-first list in any of them wins over a
    /// title-first list in any of them, so the weaker reading never hides the stronger one.
    public static func chapters(in texts: some Sequence<String>, duration: TimeInterval?) -> [EpisodeChapter] {
        let knownDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var unlisted: [[String]] = []
        for text in texts {
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            let list = timestampFirstList(in: lines, duration: knownDuration)
            if !list.isEmpty {
                return chapters(from: list)
            }
            unlisted.append(lines)
        }
        for lines in unlisted {
            let list = titleFirstList(in: lines, duration: knownDuration)
            if !list.isEmpty {
                return chapters(from: list)
            }
        }
        return []
    }

    private static func chapters(from entries: [Entry]) -> [EpisodeChapter] {
        entries.prefix(PublisherChaptersDocumentDecoder.maximumChapterCount).enumerated().map { position, entry in
            EpisodeChapter(id: position, title: entry.title, startTime: TimeInterval(entry.start))
        }
    }

    /// The bound comes before the selection, so a typo far past the end cannot anchor a
    /// selection the bound would then empty. Strictly past: a closing entry often starts
    /// exactly at the feed's duration.
    private static func inBounds(_ entries: [Entry], duration: TimeInterval?) -> [Entry] {
        duration.map { limit in entries.filter { TimeInterval($0.start) <= limit } } ?? entries
    }

    private static func timestampFirstList(in lines: [String], duration: TimeInterval?) -> [Entry] {
        var winner: [Entry] = []
        var block: [Entry] = []

        func endBlock() {
            let selection = ascendingSelection(of: inBounds(block, duration: duration))
            if selection.count >= minimumChapterCount, selection.count > winner.count {
                winner = selection
            }
            block = []
        }

        for line in lines {
            if let entry = entry(in: line) {
                block.append(entry)
            } else if !isBlank(line) {
                endBlock()
            }
        }
        endBlock()
        return winner
    }

    /// Weaker evidence than a line that leads with its time, so these must already be in
    /// order: at most one step backwards per eight entries. Headings sit between paragraphs,
    /// so every entry in the text is one list when that holds, and else the longest run is.
    private static func titleFirstList(in lines: [String], duration: TimeInterval?) -> [Entry] {
        var blocks: [[Entry]] = [[]]
        for line in lines {
            let found = entry(in: line) == nil ? titleFirstEntries(in: line) : []
            if !found.isEmpty {
                blocks[blocks.count - 1] += found
            } else if !isBlank(line) {
                blocks.append([])
            }
        }

        let runs = blocks.filter { !$0.isEmpty }
        var winner: [Entry] = []
        for candidate in runs.count > 1 ? [Array(runs.joined())] + runs : runs {
            let entries = inBounds(candidate, duration: duration)
            let stepsBack = zip(entries, entries.dropFirst()).count { $0.start > $1.start }
            let selection = ascendingSelection(of: entries)
            if stepsBack <= entries.count / 8, selection.count >= minimumChapterCount, selection.count > winner.count {
                winner = selection
            }
        }
        return winner
    }

    /// The longest strictly ascending selection, by patience sorting. An equal start never
    /// replaces a pile top, so the earlier line stays, and of equally long selections the one
    /// with the smallest starts wins: a too-large typo is the entry dropped.
    private static func ascendingSelection(of entries: [Entry]) -> [Entry] {
        var pileTops: [Int] = []
        var predecessor = [Int?](repeating: nil, count: entries.count)
        for (index, entry) in entries.enumerated() {
            var low = 0
            var high = pileTops.count
            while low < high {
                let middle = (low + high) / 2
                if entries[pileTops[middle]].start < entry.start {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low < pileTops.count, entries[pileTops[low]].start == entry.start {
                continue
            }
            predecessor[index] = low > 0 ? pileTops[low - 1] : nil
            if low == pileTops.count {
                pileTops.append(index)
            } else {
                pileTops[low] = index
            }
        }

        var selection: [Entry] = []
        var cursor = pileTops.last
        while let index = cursor {
            selection.append(entries[index])
            cursor = predecessor[index]
        }
        return selection.reversed()
    }

    private static func entry(in line: String) -> Entry? {
        guard let match = entryLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let start = ShowNotesTimestamp.seconds(of: match, in: line),
              let titleRange = Range(match.range(withName: "title"), in: line)
        else {
            return nil
        }
        // Foundation's `.whitespaces` trims U+200B, which ICU's `\s` leaves for the title group.
        let title = line[titleRange].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            return nil
        }
        return (start, String(title.prefix(PublisherChaptersDocumentDecoder.maximumTitleLength)))
    }

    /// A line whose last bracketed time closes a clause, so that each time follows its
    /// title. In `[0:15] Intro [1:30] Guest` each time leads its title instead.
    private static func titleFirstEntries(in line: String) -> [Entry] {
        let times = bracketedTimestamp.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            Range(match.range, in: line).map { (match: match, range: $0) }
        }
        guard let last = times.last, line[last.range.upperBound...].first.map({ ".;,!?".contains($0) }) ?? true else {
            return []
        }

        let dividesWithSemicolons = times.contains { line[$0.range.upperBound...].first == ";" }
        var entries: [Entry] = []
        var cursor = line.startIndex
        for (match, range) in times {
            // ICU's `\d` takes digits `Int` does not: such a time stays in the next title's text.
            guard let start = ShowNotesTimestamp.seconds(of: match, in: line) else {
                continue
            }
            let opensProse = cursor == line.startIndex && times.count > 1
            let text = line[cursor..<range.lowerBound]
            cursor = range.upperBound
            if let title = title(before: text, opensProse: opensProse, dividesWithSemicolons: dividesWithSemicolons) {
                entries.append((start, title))
            }
        }
        return entries
    }

    /// Only a line that divides its items with `;` is cut at one, and at the first colon of
    /// its lead-in sentence ("In this week's news: …"): elsewhere both belong to titles.
    private static func title(before text: Substring, opensProse: Bool, dividesWithSemicolons: Bool) -> String? {
        // One slice from the back: an end-anchored regex, or dropping one character at a
        // time, is quadratic on a long run of separators.
        guard let last = text.lastIndex(where: { !isTrailingSeparator($0) }) else {
            return nil
        }
        var title = text[...last]
        if dividesWithSemicolons, let divider = title.lastIndex(of: ";") {
            title = title[title.index(after: divider)...]
        } else if opensProse {
            if dividesWithSemicolons, let lastColon = title.range(of: ": ", options: .backwards) {
                let leadIn = afterLastSentenceEnd(in: title[..<lastColon.lowerBound]) ?? title.startIndex
                title = title[(title[leadIn...].range(of: ": ") ?? lastColon).upperBound...]
            } else if let sentence = afterLastSentenceEnd(in: title) {
                title = title[sentence...]
            }
        }

        title = title.drop(while: isLeadingSeparator)
        let number = title.prefix(3).prefix(while: \.isWholeNumber)
        if !number.isEmpty, title.dropFirst(number.count).hasPrefix(". ") {
            title = title.dropFirst(number.count + 1).drop(while: isLeadingSeparator)
        }
        for conjunction in ["and ", "plus "] where title.hasPrefix(conjunction) {
            title = title.dropFirst(conjunction.count).drop(while: \.isWhitespace)
        }
        guard let first = title.first, title.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }

        let firstWord = title.prefix { $0.isLetter || $0.isNumber }
        let capitalized = firstWord.allSatisfy(\.isLowercase) ? first.uppercased() + title.dropFirst() : String(title)
        return String(capitalized.prefix(PublisherChaptersDocumentDecoder.maximumTitleLength))
    }

    private static func afterLastSentenceEnd(in text: Substring) -> Substring.Index? {
        sentenceEnd.matches(in: String(text), range: NSRange(location: 0, length: text.utf16.count)).last
            .map { text.utf16.index(text.startIndex, offsetBy: $0.range.upperBound) }
    }

    private static func isLeadingSeparator(_ character: Character) -> Bool {
        character.isWhitespace || ",.;:!?&+|•*".contains(character) || isDash(character)
    }

    private static func isTrailingSeparator(_ character: Character) -> Bool {
        character.isWhitespace || ":|*".contains(character) || isDash(character)
    }

    private static func isDash(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.generalCategory == .dashPunctuation
    }

    private static func isBlank(_ line: String) -> Bool {
        blankLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
