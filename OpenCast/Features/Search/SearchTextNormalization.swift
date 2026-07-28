import Foundation

nonisolated enum SearchTextNormalization {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased(with: .current)
    }
}
