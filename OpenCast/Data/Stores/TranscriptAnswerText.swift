import Foundation

/// Cleans an answer for display. The model tends to echo its citations
/// inline (`[#147, #151]`, `(#60)`, `[#59 5:14–5:21]`); the chips carry
/// them, so the markers come out of the prose.
nonisolated enum TranscriptAnswerText {
    static func strippingCitationMarkers(_ text: String) -> String {
        text
            .replacing(/\s*[\[(]\s*#\d+[^\])]*[\])]/, with: "")
            .replacing(/\s+(?=[.,;:!?])/, with: "")
            .replacing(/[ \t]{2,}/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
