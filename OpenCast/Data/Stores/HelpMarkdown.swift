import Foundation

nonisolated enum HelpMarkdown {
    /// Inline markdown only (bold, italic, code, links); a parse failure falls
    /// back to the plain text so content never disappears.
    static func attributedString(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
