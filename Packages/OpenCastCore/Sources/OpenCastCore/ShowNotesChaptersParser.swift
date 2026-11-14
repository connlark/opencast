import Foundation

/// Publishers write chapter lists as timestamp lines in an episode's description because Apple Podcasts and
/// Spotify render them as chapters; this reads such a list out of the text the Show Notes section already shows.
public enum ShowNotesChaptersParser {
    public static let minimumChapterCount = 3

    private static let bullet = #"(?:\p{Pd}|[•*]|\d{1,3}\.)"#

    /// What follows an entry's time when its line is a range, which is not an entry: an optional closing bracket, a
    /// dash or the word `to`, then a second time behind an optional opening bracket. Without that connector the
    /// second time only begins the title (`(00:01:35) 9:30pm bedtime routine`). Only the digits identify the second
    /// time, because `ShowNotesTimestamp.pattern` refuses one followed by `:`, `pm` or more digits and would let
    /// `0:00 - 1:00: Intro` through. This is the range check only: an entry's own time and timestamp links keep that
    /// pattern.
    private static let rangeEnd = #"\s*+[)\]]?\s*+(?:\p{Pd}++|(?i:to))\s*+[(\[]?\s*+\d{1,2}:\d{2}"#

    /// Whitespace runs are possessive so a long line cannot backtrack through them. The separator run must be: given
    /// back one character, a line of only separators after its time (`00:00 -`) would come out as a chapter titled `-`.
    private static let entryLine = try! NSRegularExpression(
        pattern: #"^\s*+(?:"# + bullet + #"\s++)?(?:[(\[]\s*+)?"# + ShowNotesTimestamp.pattern + #"(?!"# + rangeEnd
            + #")[\s\p{Pd}:|)\]]++(?<title>.+)"#
    )

    /// `structuredText` writes `<li>` as `- `, so `<li>\n<p>…</p>\n</li>` leaves a lone bullet line between entries.
    /// Possessive, or a long run of spaces before a letter takes quadratic time to reject.
    private static let blankLine = try! NSRegularExpression(pattern: #"^\s*+"# + bullet + #"?\s*+$"#)

    private typealias Entry = (start: Int, title: String)

    /// `text` is show-notes plain text with one entry per line (`HTMLPlainText.structuredText`).
    public static func chapters(in text: String, duration: TimeInterval?) -> [EpisodeChapter] {
        let knownDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var winner: [Entry] = []
        var block: [Entry] = []

        func endBlock() {
            // The bound comes before the selection, so a typo far past the end cannot anchor a selection that the
            // bound would then empty. Strictly past: a publisher's closing entry often starts exactly at the feed's
            // duration.
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

    /// The longest strictly ascending selection, by patience sorting with predecessor links, in O(n log n).
    /// A smaller start replaces a pile's top and an equal one never does, so of two equal starts the earlier line
    /// stays, and among equally long selections the one with the smallest starts wins: a typo that is too large is
    /// the entry dropped, and the entries after it survive.
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
