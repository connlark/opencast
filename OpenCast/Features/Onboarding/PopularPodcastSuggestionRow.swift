import OpenCastCore
import SwiftUI

struct PopularPodcastSuggestionRow: View {
    let result: DirectoryPodcastResult
    let isSubscribed: Bool
    let isSubscribing: Bool
    let isDisabled: Bool
    let onSubscribe: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkPlaceholder(title: result.title, imageURL: result.artworkURL?.absoluteString, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(2)

                if let artistName = result.artistName, !artistName.isEmpty {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isSubscribing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Subscribing")
            } else if isSubscribed {
                Label("Subscribed", systemImage: "checkmark")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 118, alignment: .trailing)
            } else {
                Button(action: onSubscribe) {
                    Label("Subscribe", systemImage: "plus")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(minWidth: 118, minHeight: 44)
                }
                    .buttonStyle(.glass)
                    .disabled(isDisabled)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
