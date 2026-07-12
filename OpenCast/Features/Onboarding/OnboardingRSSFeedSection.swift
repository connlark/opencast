import SwiftUI

struct OnboardingRSSFeedSection: View {
    @Binding var feedURLString: String

    let focusedField: FocusState<OnboardingFocusedField?>.Binding
    let isSubscribing: Bool
    let canSubscribe: Bool
    let onPaste: () -> Void
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add an RSS feed")
                        .font(.headline)

                    Text("Paste the public feed URL from any podcast website.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                SymbolBadgeView(systemImage: "dot.radiowaves.right")
            }
            .accessibilityElement(children: .combine)

            urlInputField

            Button(action: onSubscribe) {
                if isSubscribing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Subscribing")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    Label("Subscribe", systemImage: "plus")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!canSubscribe || isSubscribing)
            .accessibilityIdentifier("Onboarding RSS Subscribe")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
