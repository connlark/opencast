import Foundation

/// The shape a pasted API key must have before the key sheet offers Test or
/// Save: after trimming, 8 to 512 visible ASCII characters with no
/// whitespace inside. A pasted fragment or a multi-line copy fails it.
nonisolated enum AnalysisProviderKeyFormat {
    static let lengthRange = 8...512

    static func isPlausible(_ text: String) -> Bool {
        let scalars = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        return lengthRange.contains(scalars.count) && scalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
