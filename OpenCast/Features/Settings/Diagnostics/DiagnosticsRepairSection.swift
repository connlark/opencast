import SwiftUI

struct DiagnosticsRepairSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let verifiedDownloadSummary: String

    var body: some View {
        Section {
            Button(
                "Repair Sync Duplicates",
                systemImage: "wrench.adjustable",
                action: repairSyncDuplicates
            )
            .disabled(appModel.syncStatus.isRepairingDuplicates)

            if appModel.syncStatus.isRepairingDuplicates {
                ProgressView("Repairing")
            }

            if let lastRepairResult = appModel.syncStatus.lastRepairResult {
                SyncRepairResultSummaryView(result: lastRepairResult)
            } else {
                LabeledContent {
                    Text("Not Run")
                } label: {
                    Label("Last Repair", systemImage: "clock.badge.questionmark")
                }
                .accessibilityLabel("Last Repair, Not Run")
            }

            if let errorMessage = appModel.syncStatus.lastRepairErrorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Sync Repair")
        } footer: {
            Text("Merges duplicate synced subscription and progress rows.")
        }

        Section {
            Button(
                "Merge Duplicate Episodes",
                systemImage: "rectangle.stack.badge.minus",
                action: mergeDuplicateEpisodes
            )
            .disabled(appModel.syncStatus.isMergingDuplicateEpisodes)

            if appModel.syncStatus.isMergingDuplicateEpisodes {
                ProgressView("Merging")
            }

            if let mergeResult = appModel.syncStatus.lastEpisodeMergeResult {
                EpisodeMergeResultSummaryView(result: mergeResult)
            } else {
                LabeledContent {
                    Text("Not Run")
                } label: {
                    Label("Last Merge", systemImage: "clock.badge.questionmark")
                }
                .accessibilityLabel("Last Merge, Not Run")
            }

            if let errorMessage = appModel.syncStatus.lastEpisodeMergeErrorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Episode Identity")
        } footer: {
            Text("Refetches every feed and folds episodes whose identity changed back onto their current entries.")
        }

        Section {
            LabeledContent {
                Text(verifiedDownloadSummary)
            } label: {
                Label("Verified Downloads", systemImage: "checkmark.seal")
            }

            LabeledContent {
                Text("\(appModel.downloads.duplicateRepairCount)")
            } label: {
                Label("Download Repairs", systemImage: "arrow.down.circle")
            }

            LabeledContent {
                Text("\(appModel.transcriptions.duplicateRepairCount)")
            } label: {
                Label("Transcript Repairs", systemImage: "text.quote")
            }

            LabeledContent {
                Text("\(appModel.adAnalyses.duplicateRepairCount)")
            } label: {
                Label("Analysis Repairs", systemImage: "waveform")
            }
        } header: {
            Text("Local Data Repair")
        } footer: {
            Text("Collapses duplicate local download, transcript, and analysis records.")
        }
    }

    private func repairSyncDuplicates() {
        Task {
            await appModel.syncStatus.repairDuplicates(
                modelContext: modelContext,
                libraryStore: appModel.library
            )
        }
    }

    private func mergeDuplicateEpisodes() {
        Task {
            await appModel.syncStatus.mergeDuplicateEpisodes(
                modelContext: modelContext,
                libraryStore: appModel.library
            )
        }
    }
}
