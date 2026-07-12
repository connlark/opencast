import OpenCastCore
import SwiftUI

struct SearchAddFeedSection: View {
    let feedURLString: String
    let activePodcastIDs: Set<String>
    let subscribingFeedURLString: String?
    let onAdd: () -> Void

    var body: some View {
        Section("RSS Feed") {
            HStack(spacing: 12) {
                Text(feedURLString)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Adding Feed")
                } else if isSubscribed {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Button("Add Feed", systemImage: "plus", action: onAdd)
                        .disabled(subscribingFeedURLString != nil)
                }
            }
            .frame(minHeight: 44)
        }
    }

    private var canonicalFeedURLString: String {
        URLCanonicalizer.canonicalString(forRawString: feedURLString)
    }

    private var isSubscribed: Bool {
        activePodcastIDs.contains(canonicalFeedURLString)
    }

    private var isSubscribing: Bool {
        guard let subscribingFeedURLString else {
            return false
        }

        return URLCanonicalizer.canonicalString(forRawString: subscribingFeedURLString) == canonicalFeedURLString
    }
}
