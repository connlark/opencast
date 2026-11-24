import OpenCastCore
import SwiftUI

struct PodcastResultRow: View {
    enum Status {
        case addable
        case adding
        case justAdded
        case inLibrary
        case noFeed
    }

    let result: DirectoryPodcastResult
    let status: Status
    let openHint: String
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                PodcastRowLabel(title: result.title, author: result.artistName, artworkURL: result.artworkURL?.absoluteString) {
                    switch status {
                    case .inLibrary:
                        PodcastInLibraryLabel()
                            .labelStyle(PodcastResultMarkLabelStyle())
                            .font(.caption)
                            .padding(.top, 2)
                    case .noFeed:
                        Label("No RSS feed", systemImage: "exclamationmark.circle")
                            .labelStyle(PodcastResultMarkLabelStyle())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    case .addable, .adding, .justAdded:
                        EmptyView()
                    }
                }
                .padding(.vertical, 2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(status == .noFeed)
            .accessibilityHint(openHint)

            switch status {
            case .addable:
                PodcastQuickAddButton(phase: .add, showTitle: result.title, action: onAdd)
            case .adding:
                PodcastQuickAddButton(phase: .adding, showTitle: result.title, action: onAdd)
            case .justAdded:
                PodcastQuickAddButton(phase: .added, showTitle: result.title, action: onOpen)
            case .inLibrary, .noFeed:
                EmptyView()
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            64
        }
    }
}

#Preview("Rows") {
    PodcastPreviewPreviewSamples.results([
        (PodcastPreviewPreviewSamples.theSignal, .addable),
        (PodcastPreviewPreviewSamples.signalAndNoise, .inLibrary),
        (PodcastPreviewPreviewSamples.theSignalPath, .justAdded),
        (PodcastPreviewPreviewSamples.nightSignal, .adding),
        (PodcastPreviewPreviewSamples.signalCastLive, .noFeed),
    ])
}
