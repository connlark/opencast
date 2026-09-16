import SwiftUI

/// One conversation row: the listener's question right-aligned, the
/// assistant's answer (streaming, validated, or failed) left-aligned.
struct TranscriptAskMessageRow: View {
    let message: TranscriptAskMessage
    let onSeek: (TranscriptAskCitation) -> Void

    var body: some View {
        switch message.content {
        case .question(let text):
            Text(text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.tint.quaternary, in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("Transcript Ask Question")
        case .streaming, .answer, .failure:
            TranscriptAskAnswerView(content: message.content, onSeek: onSeek)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
