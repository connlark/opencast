import SwiftUI

/// The Ad Detection queue screen: live per-episode status for the active,
/// pending, and finished items of the current drain session, plus the
/// queue-level affordances (continue in background, cap retry, resume,
/// model consent).
struct AdDetectionQueueView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = AdDetectionQueuePresentation(
            snapshot: appModel.adFreePass.queueSnapshot,
            isBackgroundSessionArmed: appModel.adFreePassBackgroundSession.isArmed
        )

        List {
            if presentation.isEmpty {
                ContentUnavailableView(
                    "No ad detection in progress",
                    systemImage: "megaphone",
                    description: Text("Detect ads from an episode's context menu, or turn on automatic detection for a show.")
                )
            } else {
                if let affordance = presentation.affordance {
                    Section {
                        affordanceRow(affordance)
                    }
                }

                if !presentation.rows.isEmpty {
                    Section {
                        ForEach(presentation.rows) { row in
                            AdDetectionQueueRowView(row: row)
                        }
                    }
                }

                if !presentation.finishedRows.isEmpty {
                    Section("Finished") {
                        ForEach(presentation.finishedRows) { row in
                            AdDetectionQueueRowView(row: row)
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .default, value: presentation)
        .navigationTitle("Ad Detection")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func affordanceRow(_ affordance: AdDetectionQueuePresentation.Affordance) -> some View {
        switch affordance {
        case .continueInBackground:
            Button("Continue in Background", systemImage: "arrow.down.app", action: continueInBackground)
        case .backgroundContinuationArmed:
            Label("Continues in the background.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .retryCapDeferred:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    EpisodeAdFreePassPresentation.capDeferred.statusText,
                    systemImage: "hourglass"
                )
                .foregroundStyle(.secondary)
                Button("Retry", action: resumeQueue)
            }
        case .resumeInterrupted:
            Button("Resume", systemImage: "play.circle", action: resumeQueue)
        case .downloadModelConsent(let byteCount):
            Button(
                EpisodeAdFreePassPresentation.awaitingModelConsent(byteCount: byteCount).primaryActionTitle,
                systemImage: "arrow.down.circle",
                action: resumeQueue
            )
        }
    }

    private func continueInBackground() {
        appModel.armBackgroundContinuationForActiveQueue()
    }

    private func resumeQueue() {
        appModel.adFreePass.resumePausedQueue()
    }
}
