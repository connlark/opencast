import SwiftUI

struct AddPodcastRSSView: View {
    @Binding var selectedMode: AddPodcastMode
    @Binding var feedURLString: String

    let subscriptionErrorMessage: String?
    let clipboardErrorMessage: String?
    let isSubscribing: Bool
    let canSubscribe: Bool
    let onPaste: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Add Podcast")
                    .font(.largeTitle)
                    .bold()

                AddPodcastModePicker(selectedMode: $selectedMode)
                    .padding(8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 32))

                VStack(alignment: .leading, spacing: 12) {
                    Text("RSS Feed URL")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    AddPodcastURLInputField(
                        feedURLString: $feedURLString,
                        isPasteEnabled: !isSubscribing,
                        onPaste: onPaste,
                        onSubmit: onSubmit
                    )

                    Text("Enter the URL of the podcast RSS feed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                AddPodcastPasteCard(
                    isPasteEnabled: !isSubscribing,
                    onPaste: onPaste
                )

                if let clipboardErrorMessage {
                    Label(clipboardErrorMessage, systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                if let subscriptionErrorMessage {
                    Label(subscriptionErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Label("Make sure the RSS feed URL is valid and publicly accessible.", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        .background(.background)
    }
}
