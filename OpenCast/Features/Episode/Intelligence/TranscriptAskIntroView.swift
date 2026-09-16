import SwiftUI

/// The empty conversation: what Ask does and two questions to start with.
struct TranscriptAskIntroView: View {
    static let suggestions = ["What is this episode about?", "What happens at the end?"]

    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ask About This Episode", systemImage: "apple.intelligence")
                .font(.headline)
            Text("Answers come only from this episode’s transcript, with times you can tap to listen. Generated with Apple Intelligence.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            onSuggestion(suggestion)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Transcript Ask Intro")
    }
}
