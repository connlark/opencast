import SwiftUI

/// The assistant side of one turn. A verified answer carries tappable
/// citation chips; an unverifiable one shows its text with a note and no
/// chips; an unanswerable one says the transcript does not cover it; a
/// failed turn shows the calm per-request message.
struct TranscriptAskAnswerView: View {
    let content: TranscriptAskMessage.Content
    let onSeek: (TranscriptAskCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch content {
            case .streaming(let text):
                if text.isEmpty {
                    ProgressView()
                        .accessibilityLabel("Answering")
                } else {
                    HStack(alignment: .bottom, spacing: 8) {
                        Text(text)
                            .font(.body)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            case .answer(let answer):
                answerContent(answer)
            case .failure(let failure):
                Label(Self.message(for: failure), systemImage: "exclamationmark.bubble")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("Transcript Ask Failure")
            case .question:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Transcript Ask Answer")
    }

    @ViewBuilder
    private func answerContent(_ answer: TranscriptAskAnswer) -> some View {
        if !answer.isAnswerable {
            Label("The transcript doesn’t cover that.", systemImage: "questionmark.circle")
                .font(.body)
                .accessibilityIdentifier("Transcript Ask Unanswerable")
        } else {
            Text(answer.text)
                .font(.body)
            if answer.isVerified {
                GlassEffectContainer {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(answer.citations) { citation in
                                TranscriptCitationChip(time: citation.start) {
                                    onSeek(citation)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                Label("Couldn’t verify this answer against the transcript.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("Transcript Ask Unverified Note")
            }
        }
    }

    /// Ask wording for the shared failures: a decline is per question here,
    /// and the conversation goes on.
    private static func message(for failure: TranscriptIntelligenceFailure) -> String {
        switch failure {
        case .guardrailViolation, .refusal:
            "Apple’s model declined to answer this question. Try asking something else."
        default:
            failure.userMessage ?? ""
        }
    }
}
