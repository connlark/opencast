import Foundation

nonisolated enum AnalysisProviderKeyFormat {
    static let lengthRange = 8...512

    static func isPlausible(_ text: String) -> Bool {
        let scalars = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        return lengthRange.contains(scalars.count) && scalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
