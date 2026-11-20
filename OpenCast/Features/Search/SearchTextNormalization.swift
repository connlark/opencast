import Foundation

nonisolated enum SearchTextNormalization {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    static func normalize(_ text: String) -> String {
        // ASCII has no diacritics, width variants or dotless I, so this path skips a
        // locale-folding allocation per word without changing the result.
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        // Locale-invariant folding maps "IŞIK" to "isik" but leaves "ışık" as "ısık"; folding
        // the dotless ı as well makes both casings converge in every locale.
        return text.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: foldingLocale
        )
        .lowercased()
        .replacing("ı", with: "i")
    }

    static func searchTokens(in text: String) -> [String] {
        // ASCII fast path: no grapheme or property lookups per character in large catalogs.
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return text.utf8.split { byte in
                !((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57))
            }.map { String(decoding: $0, as: UTF8.self).lowercased() }
        }
        return text.split { !$0.isLetter && !$0.isNumber }
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    static func uniqueSearchTokens(in text: String) -> [String] {
        var seen: Set<String> = []
        return searchTokens(in: text).filter { seen.insert($0).inserted }
    }

    static func canonicalSearchText(_ text: String) -> String {
        searchTokens(in: text).joined(separator: " ")
    }
}
