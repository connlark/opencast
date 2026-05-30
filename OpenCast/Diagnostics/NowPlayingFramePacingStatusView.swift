#if DEBUG
import SwiftUI

/// Exposes the frame-pacing probe's flushed session summaries to UI tests.
///
/// xcodebuild runs UI tests on an ephemeral simulator clone whose container is
/// not readable from the host, so the probe's on-disk logs are unreachable. This
/// 1x1 near-invisible element publishes the summaries through the accessibility
/// tree, letting the UI test read `.value` and print it into the host test log.
struct NowPlayingFramePacingStatusView: View {
    @State private var summary = "pending"

    var body: some View {
        Text("Frame Pacing Summary")
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityIdentifier("Frame Pacing Summary")
            .accessibilityLabel("Frame Pacing Summary")
            .accessibilityValue(summary)
            .task { await observeSummaries() }
    }

    private func observeSummaries() async {
        while !Task.isCancelled {
            let summaries = NowPlayingFramePacingProbe.shared.sessionSummaries
            let next = summaries.isEmpty ? "pending" : summaries.joined(separator: " || ")
            if next != summary {
                summary = next
            }

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }
    }
}
#endif
