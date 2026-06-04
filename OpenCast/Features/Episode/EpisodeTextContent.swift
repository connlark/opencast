import Foundation

struct EpisodeTextContent: Equatable, Sendable {
    let summary: String?
    let showNotesPlainText: String?
    let showNotesShouldRender: Bool

    static let empty = EpisodeTextContent(
        summary: nil,
        showNotesPlainText: nil,
        showNotesShouldRender: false
    )

    @concurrent
    static func resolving(summaryHTML: String?, showNotesHTML: String?) async -> EpisodeTextContent {
        let summary = summaryHTML.map(HTMLPlainText.collapsedText).flatMap(trimmedNonEmpty)
        let plainShowNotes = showNotesHTML.map(HTMLPlainText.structuredText).flatMap(trimmedNonEmpty)

        return EpisodeTextContent(
            summary: summary,
            showNotesPlainText: plainShowNotes,
            showNotesShouldRender: showNotesAddsContent(showNotes: plainShowNotes, summary: summary)
        )
    }

    nonisolated private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func showNotesAddsContent(showNotes: String?, summary: String?) -> Bool {
        guard let showNotes else {
            return false
        }

        guard let summary else {
            return true
        }

        let normalizedShowNotes = normalizedForDuplicateComparison(showNotes)
        let normalizedSummary = normalizedForDuplicateComparison(summary)

        guard !normalizedShowNotes.isEmpty, !normalizedSummary.isEmpty else {
            return false
        }

        if normalizedShowNotes == normalizedSummary {
            return false
        }

        if normalizedShowNotes.contains(normalizedSummary) {
            let addedCharacterCount = normalizedShowNotes.count - normalizedSummary.count
            return addedCharacterCount > 240
        }

        return true
    }

    nonisolated private static func normalizedForDuplicateComparison(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
