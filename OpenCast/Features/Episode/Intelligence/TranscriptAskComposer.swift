import SwiftUI

/// The question field and send button pinned under the conversation.
struct TranscriptAskComposer: View {
    @Binding var draft: String
    let isResponding: Bool
    let isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                TextField("Ask about this episode", text: $draft)
                    .textFieldStyle(.plain)
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit(onSend)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityIdentifier("Transcript Ask Composer")
                Button("Send", systemImage: "arrow.up", action: onSend)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .labelStyle(.iconOnly)
                    .disabled(!canSend)
                    .accessibilityIdentifier("Transcript Ask Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
