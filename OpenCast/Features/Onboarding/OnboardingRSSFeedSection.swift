import SwiftUI

struct OnboardingRSSFeedSection: View {
    @Binding var feedURLString: String

    let focusedField: FocusState<OnboardingFocusedField?>.Binding
    let isSubscribing: Bool
    let canSubscribe: Bool
    let onPaste: () -> Void
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RSS Feed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                urlInputField

                Button(action: onSubscribe) {
                    if isSubscribing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Subscribing")
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Label("Subscribe", systemImage: "plus")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSubscribe || isSubscribing)
                .accessibilityIdentifier("Onboarding RSS Subscribe")
            }

            Text("Use the public RSS feed URL from any podcast website.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var urlInputField: some View {
        HStack(spacing: 14) {
            TextField(
                "RSS Feed URL",
                text: $feedURLString,
                prompt: Text("https://example.com/podcast/rss")
            )
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused(focusedField, equals: .feedURL)
            .onSubmit(hideKeyboard)
            .accessibilityIdentifier("RSS Feed URL")

            Divider()
                .frame(height: 30)

            Button("Paste", systemImage: "doc.on.clipboard", action: onPaste)
                .disabled(isSubscribing)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .font(.body)
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))
    }

    private func hideKeyboard() {
        focusedField.wrappedValue = nil
    }
}
