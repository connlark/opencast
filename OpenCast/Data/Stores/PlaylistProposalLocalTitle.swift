nonisolated enum PlaylistProposalLocalTitle {
    static let maximumLength = 60
    static let fallbackName = "Playlist"
    private static let trailingSeparators: Set<Character> = [":", "-", "–", "—", "#", "|", ","]

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
