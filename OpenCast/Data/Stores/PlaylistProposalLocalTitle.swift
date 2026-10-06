/// Playlist names chosen on the device, for a simpler answer that carries
/// episode numbers only.
nonisolated enum PlaylistProposalLocalTitle {
    static let maximumLength = 60
    /// The name of a group whose episodes have no titles.
    static let fallbackName = "Playlist"
    /// Dropped from the end of a shared title prefix ("Harbor Tales —") and of
    /// a cut name.
    private static let trailingSeparators: Set<Character> = [":", "-", "–", "—", "#", "|", ","]

    /// Names for proposals a simpler answer returned without any. A typed request names them after the request,
    /// first letter capitalised ("Harbor stories", then "Harbor stories 2", "Harbor stories 3"); suggestions take
    /// the longest run of leading words (2 or more) that all their episode titles share, trailing ":", "-", "–",
    /// "—", "#", "|" and "," trimmed, else the first episode's title. Groups whose names would collide (a show whose
    /// every title starts "Show Name – …") are named from `shortTitles`, the titles with that show-wide prefix
    /// dropped, when given. A name already used gets " 2", " 3"; a group with no titles is `fallbackName`.
    /// Whitespace collapsed; cut at a word boundary to `maximumLength`.
    static func titles(
        forEpisodeTitles episodeTitles: [[String]],
        shortTitles: [[String]]? = nil,
        mode: PlaylistOrganizerMode,
        request: String?
    ) -> [String] {
        let requestName = capitalizingFirstLetter(collapsingWhitespace(request ?? ""))
        if mode == .prompted, !requestName.isEmpty {
            return episodeTitles.indices.map { offset in
                name(requestName, number: offset == 0 ? nil : offset + 1)
            }
        }
        var bases = episodeTitles.map(suggestionName(for:))
        if let shortTitles, shortTitles.count == episodeTitles.count {
            var counts: [String: Int] = [:]
            for base in bases {
                counts[base, default: 0] += 1
            }
            for offset in bases.indices where counts[bases[offset], default: 0] > 1 {
                let shortBase = suggestionName(for: shortTitles[offset])
                if !shortBase.isEmpty {
                    bases[offset] = shortBase
                }
            }
        }
        var used = Set<String>()
        return bases.map { suggested in
            let base = suggested.isEmpty ? fallbackName : suggested
            var title = name(base, number: nil)
            var number = 2
            while !used.insert(title).inserted {
                title = name(base, number: number)
                number += 1
            }
            return title
        }
    }

    /// The longest shared run of leading words, compared case-sensitively as
    /// written, when it still holds 2 or more words once trimmed; otherwise
    /// the first non-empty episode title.
    private static func suggestionName(for titles: [String]) -> String {
        let words = titles.map { $0.split(whereSeparator: \.isWhitespace) }
        guard let first = words.first else {
            return ""
        }
        var sharedCount = first.count
        for other in words.dropFirst() {
            sharedCount = min(sharedCount, zip(first, other).prefix { $0.0 == $0.1 }.count)
        }
        let prefix = trimmingTrailingSeparators(first.prefix(sharedCount).joined(separator: " "))
        if prefix.split(separator: " ").count >= 2 {
            return prefix
        }
        return titles.lazy.map(collapsingWhitespace).first { !$0.isEmpty } ?? ""
    }

    /// `base`, cut so the whole name including " `number`" fits `maximumLength`.
    private static func name(_ base: String, number: Int?) -> String {
        let suffix = number.map { " \($0)" } ?? ""
        return cut(base, to: maximumLength - suffix.count) + suffix
    }

    private static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        var kept = ""
        for word in text.split(separator: " ") {
            let candidate = kept.isEmpty ? String(word) : kept + " " + word
            guard candidate.count <= limit else {
                break
            }
            kept = candidate
        }
        let trimmed = trimmingTrailingSeparators(kept)
        return trimmed.isEmpty ? String(text.prefix(limit)) : trimmed
    }

    private static func trimmingTrailingSeparators(_ text: String) -> String {
        var text = Substring(text)
        while let last = text.last, last.isWhitespace || trailingSeparators.contains(last) {
            text.removeLast()
        }
        return String(text)
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first else {
            return text
        }
        return first.uppercased() + text.dropFirst()
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
