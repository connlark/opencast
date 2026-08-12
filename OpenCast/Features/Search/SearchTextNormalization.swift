import Foundation

nonisolated enum SearchTextNormalization {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    static func normalize(_ text: String) -> String {
        // Locale-invariant folding keeps index and query normalization
        // identical across device-locale changes, but it cannot express the
        // Turkish dotted/dotless-I pairs: invariant folding maps "IŞIK" to
        // "isik" while leaving "ışık" as "ısık". Fold dotless ı explicitly so
        // both casings of a Turkish word converge to one form in every locale.
        text.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: foldingLocale
        )
        .lowercased()
        .replacing("ı", with: "i")
    }

    static func searchTokens(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
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
