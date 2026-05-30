import SwiftUI

struct AddPodcastURLInputField: View {
    @Binding var feedURLString: String

    let isPasteEnabled: Bool
    let onPaste: () -> Void
    let onSubmit: () -> Void

    var body: some View {
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
            .submitLabel(.go)
            .onSubmit(onSubmit)
            .accessibilityIdentifier("RSS Feed URL")

            Divider()
                .frame(height: 30)

            Button("Paste", systemImage: "doc.on.clipboard", action: onPaste)
                .disabled(!isPasteEnabled)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .font(.body)
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))
    }
}
