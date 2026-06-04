import Foundation

extension String {
    nonisolated var plainTextFromHTML: String {
        HTMLPlainText.collapsedText(from: self)
    }

    var initials: String {
        let initials = split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return initials.isEmpty ? "OC" : initials.uppercased()
    }

    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
