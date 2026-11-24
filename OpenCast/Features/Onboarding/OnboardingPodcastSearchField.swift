import SwiftUI

struct OnboardingPodcastSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Podcast name or feed URL", text: $text)
                .accessibilityLabel("Podcast name or feed URL")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(isFocused)

            if !text.isEmpty {
                Button(action: clear) {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
            }
        }
        .font(.body)
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(minHeight: 50)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func clear() {
        text = ""
        isFocused.wrappedValue = true
    }
}
