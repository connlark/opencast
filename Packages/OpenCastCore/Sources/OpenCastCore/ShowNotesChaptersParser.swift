import Foundation

public enum ShowNotesChaptersParser {
    public static let minimumChapterCount = 3

    private static let bullet = #"(?:\p{Pd}|[•*]|\d{1,3}\.)"#

    /// A time range (`0:00 - 1:00`) is not an entry; without a dash or `to`, a second time
    /// begins the title. Only digits identify the second time: `ShowNotesTimestamp.pattern`
    /// refuses one followed by `:`, so `0:00 - 1:00: Intro` would get through.
    private static let rangeEnd = #"\s*+[)\]]?\s*+(?:\p{Pd}++|(?i:to))\s*+[(\[]?\s*+\d{1,2}:\d{2}"#

    /// Whitespace runs are possessive so a long line cannot backtrack through them. Given back
    /// one character, the separator run would turn a line like `00:00 -` into a chapter `-`.
    private static let entryLine = try! NSRegularExpression(
        pattern: #"^\s*+(?:"# + bullet + #"\s++)?(?:[(\[]\s*+)?"# + ShowNotesTimestamp.pattern + #"(?!"# + rangeEnd
            + #")[\s\p{Pd}:|)\]]++(?<title>.+)"#
    )

    /// `structuredText` writes `<li>` as `- `, so a lone bullet line can sit between entries.
    /// Possessive, or a long run of spaces before a letter takes quadratic time to reject.
    private static let blankLine = try! NSRegularExpression(pattern: #"^\s*+"# + bullet + #"?\s*+$"#)

    private typealias Entry = (start: Int, title: String)

    /// `text` is show-notes plain text with one entry per line (`HTMLPlainText.structuredText`).
    public static func chapters(in text: String, duration: TimeInterval?) -> [EpisodeChapter] {
        let knownDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var winner: [Entry] = []
        var block: [Entry] = []

        func endBlock() {
            // The bound comes before the selection, so a typo far past the end cannot
            // anchor a selection the bound would then empty. Strictly past: a closing
            // entry often starts exactly at the feed's duration.
            let inBounds = knownDuration.map { limit in block.filter { TimeInterval($0.start) <= limit } } ?? block
            let selection = ascendingSelection(of: inBounds)
            if selection.count >= minimumChapterCount, selection.count > winner.count {
                winner = selection
            }
            block = []
        }

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(line)
            if let entry = entry(in: line) {
                block.append(entry)
            } else if !isBlank(line) {
                endBlock()
            }
        }
        endBlock()

        return winner.prefix(PublisherChaptersDocumentDecoder.maximumChapterCount).enumerated().map { position, entry in
            EpisodeChapter(id: position, title: entry.title, startTime: TimeInterval(entry.start))
        }
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

    private static func isBlank(_ line: String) -> Bool {
        blankLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
