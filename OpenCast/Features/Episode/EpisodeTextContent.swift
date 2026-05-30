import Foundation

struct EpisodeTextContent: Equatable, Sendable {
    let summary: String?
    let showNotesHTML: String?
    let showNotesPlainText: String?
    let showNotesNeedsWebView: Bool
    let showNotesShouldRender: Bool

    static let empty = EpisodeTextContent(
        summary: nil,
        showNotesHTML: nil,
        showNotesPlainText: nil,
        showNotesNeedsWebView: false,
        showNotesShouldRender: false
    )

    @concurrent
    static func resolving(summaryHTML: String?, showNotesHTML: String?) async -> EpisodeTextContent {
        let summary = summaryHTML.map(plainTextFromHTML).flatMap(trimmedNonEmpty)
        let html = showNotesHTML.flatMap(trimmedNonEmpty)
        let plainShowNotes = html.map(plainTextFromHTML).flatMap(trimmedNonEmpty)

        return EpisodeTextContent(
            summary: summary,
            showNotesHTML: html,
            showNotesPlainText: plainShowNotes,
            showNotesNeedsWebView: html.map(needsWebViewForShowNotes) ?? false,
            showNotesShouldRender: showNotesAddsContent(showNotes: plainShowNotes, summary: summary)
        )
    }

    nonisolated private static func plainTextFromHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacing("&amp;", with: "&")
            .replacing("&quot;", with: "\"")
            .replacing("&#39;", with: "'")
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func needsWebViewForShowNotes(_ html: String) -> Bool {
        html.range(
            of: #"<(a|p|br|ul|ol|li|img|iframe|blockquote|h[1-6])\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
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
