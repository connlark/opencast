import OpenCastCore
import SwiftUI

/// Presented when a directory result's candidate feeds materially
/// differ: both parsed catalogs are shown with provenance, and the
/// primary action follows the resolver's recommendation.
struct DirectoryFeedChoiceView: View {
    let pending: DirectorySubscriptionFlowStore.PendingChoice
    let onSelect: (ResolvedFeedCandidate) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Recommended") {
                    DirectoryFeedCandidateOptionRow(
                        candidate: pending.choice.primary,
                        onSubscribe: selectPrimary
                    )
                }

                Section(secondarySectionTitle) {
                    DirectoryFeedCandidateOptionRow(
                        candidate: pending.choice.secondary,
                        onSubscribe: selectSecondary
                    )
                }
            }
            .navigationTitle(pending.result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var explanation: String {
        switch pending.choice.reason {
        case .fullerFeedPromoted:
            "Another feed for this show is up to date and carries many more episodes. The fuller feed is recommended."
        case .fullerFeedStale:
            "A fuller feed exists for this show, but it is no longer updating. The current feed stays recommended."
        case .fullerFeedSalvaged:
            "A fuller feed exists for this show, but it could not be fully read. The current feed stays recommended."
        }
    }

    private var secondarySectionTitle: String {
        switch pending.choice.reason {
        case .fullerFeedPromoted:
            "Original Feed"
        case .fullerFeedStale:
            "Full Archive — No Longer Updating"
        case .fullerFeedSalvaged:
            "Fuller Feed — Partially Read"
        }
    }

    private func selectPrimary() {
        onSelect(pending.choice.primary)
    }

    private func selectSecondary() {
        onSelect(pending.choice.secondary)
    }
}

struct DirectoryFeedCandidateOptionRow: View {
    let candidate: ResolvedFeedCandidate
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Source", value: sourceName)
            if let host = candidate.candidate.feedURL.host() {
                LabeledContent("Host", value: host)
            }
            LabeledContent("Episodes", value: episodeCountText)
            if let newestEpisodeDate = candidate.newestEpisodeDate {
                LabeledContent("Newest Episode") {
                    Text(newestEpisodeDate, format: .dateTime.day().month().year())
                }
            }

            Button("Subscribe", systemImage: "plus", action: onSubscribe)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
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
