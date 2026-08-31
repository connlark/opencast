import OpenCastCore
import SwiftUI

struct DirectoryFeedCandidateOptionRow: View {
    let candidate: ResolvedFeedCandidate
    let title: String
    let isRecommended: Bool
    let actionTitle: String
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                if isRecommended {
                    Label("Recommended", systemImage: "checkmark.seal.fill")
                        .font(.subheadline)
                        .bold()
                }

                Text(title)
                    .font(.title3)
                    .bold()
            }

            VStack(spacing: 12) {
                DirectoryFeedCandidateMetadataRow(label: "Source", value: Text(sourceName))
                if let host = candidate.candidate.feedURL.host() {
                    DirectoryFeedCandidateMetadataRow(label: "Host", value: Text(host))
                }
                DirectoryFeedCandidateMetadataRow(label: "Episodes", value: Text(episodeCountText))
                if let newestEpisodeDate = candidate.newestEpisodeDate {
                    DirectoryFeedCandidateMetadataRow(
                        label: "Newest Episode",
                        value: Text(
                            newestEpisodeDate,
                            format: .dateTime.day().month().year()
                        )
                    )
                }
            }

            subscribeButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            isRecommended ? .regular.tint(Color.accentColor.opacity(0.18)) : .regular,
            in: .rect(cornerRadius: 24)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(isRecommended ? "Recommended Feed" : "Alternate Feed")
    }

    @ViewBuilder
    private var subscribeButton: some View {
        if isRecommended {
            Button(action: onSubscribe) {
                Label(actionTitle, systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.glassProminent)
        } else {
            Button(action: onSubscribe) {
                Text(actionTitle)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.glass)
        }
    }

    private var sourceName: String {
        switch candidate.candidate.source {
        case .apple:
            "Apple"
        case .podcastIndex:
            "Podcast Index"
        }
    }

    private var episodeCountText: String {
        candidate.isSalvaged
            ? "At least \(candidate.episodeCount)"
            : "\(candidate.episodeCount)"
    }
}
