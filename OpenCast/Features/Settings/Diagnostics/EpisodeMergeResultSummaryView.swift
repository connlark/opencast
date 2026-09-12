import SwiftUI

struct EpisodeMergeResultSummaryView: View {
    let result: EpisodeMergeResult

    var body: some View {
        Group {
            LabeledContent {
                Text(result.displayStatus)
            } label: {
                Label("Last Merge", systemImage: "clock.badge.checkmark")
            }
            .accessibilityLabel("Last Merge, \(result.displayStatus)")
            LabeledContent {
                Text("\(result.feedsProcessed)")
            } label: {
                Label("Feeds Checked", systemImage: "dot.radiowaves.up.forward")
            }
            LabeledContent {
                Text("\(result.episodesMigrated)")
            } label: {
                Label("Episodes Merged", systemImage: "arrow.triangle.merge")
            }
            if !result.failedFeedURLs.isEmpty {
                LabeledContent {
                    Text("\(result.failedFeedURLs.count)")
                } label: {
                    Label("Feeds Unreachable", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }
}
