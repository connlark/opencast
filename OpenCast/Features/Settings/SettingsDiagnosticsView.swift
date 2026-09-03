import SwiftData
import SwiftUI

struct SettingsDiagnosticsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var subscriptionRecordCount: Int?
    @State private var progressRecordCount: Int?
    @State private var syncDetailsErrorMessage: String?
    @State private var refreshLogs: [RefreshLogSnapshot]?
    @State private var verifiedDownloadSummary = "—"

    var body: some View {
        Form {
            SettingsAppleSpeechSection()

            SettingsTranscriptionModelSection(
                includesModelPicker: true,
                sectionTitle: "Whisper Model"
            )

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
                Text("Repair merges logical duplicates in CloudKit-backed subscriptions and episode progress.")
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
                Text("Merge refetches every subscribed feed and folds episodes whose identity changed (publisher GUID or hosting changes) back onto their current entries, carrying progress, downloads, and transcripts.")
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
                Text("Repairs collapse duplicate local download, transcript, and analysis records left behind by episode identity changes. A verified download has a stored hash matching the audio file on disk.")
            }

            Section("Refresh Logs") {
                if let latestRefreshLog = refreshLogs?.first {
                    RefreshLogSummaryRow(title: "Latest Refresh", log: latestRefreshLog)
                } else {
                    LabeledContent("Latest Refresh", value: "Never")
                }

                if let latestRefreshFailure {
                    RefreshLogSummaryRow(title: "Latest Failure", log: latestRefreshFailure)
                } else {
                    LabeledContent("Latest Failure", value: "None")
                }

                LabeledContent("Retained Logs", value: refreshLogs.map { "\($0.count)" } ?? "Not Loaded")

                if let refreshLogs, !refreshLogs.isEmpty {
                    NavigationLink {
                        RefreshLogListView(logs: refreshLogs)
                    } label: {
                        Label("Recent Logs", systemImage: "list.bullet.clipboard")
                    }
                }
            }

            Section("Sync Details") {
                LabeledContent {
                    Text(OpenCastModelContainerFactory.cloudKitContainerIdentifier)
                } label: {
                    Label("CloudKit Container", systemImage: "shippingbox")
                }

                LabeledContent {
                    Text(appModel.syncStatus.accountStatus.displayName)
                } label: {
                    Label("iCloud Account", systemImage: "icloud")
                }

                LabeledContent {
                    Text(subscriptionRecordCount.map { "\($0)" } ?? "Not Loaded")
                } label: {
                    Label("Subscription Rows", systemImage: "books.vertical")
                }

                LabeledContent {
                    Text(progressRecordCount.map { "\($0)" } ?? "Not Loaded")
                } label: {
                    Label("Progress Rows", systemImage: "waveform.path.ecg")
                }

                Button(
                    "Refresh Sync Details",
                    systemImage: "arrow.clockwise",
                    action: refreshSyncDetails
                )

                if let syncDetailsErrorMessage {
                    Text(syncDetailsErrorMessage)
                        .foregroundStyle(.red)
                }
            }

            #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
            NotificationSecurityDiagnosticsSection()
            NotificationRegistrationDiagnosticsSection()
            NotificationSubscriptionDiagnosticsSection()
            NotificationRouteDiagnosticsSection()
            #endif
        }
        .navigationTitle("Diagnostics")
        .contentMargins(.bottom, 72, for: .scrollContent)
        .task {
            await refreshSyncDetailsNow()
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

    private func refreshSyncDetails() {
        Task {
            await refreshSyncDetailsNow()
        }
    }

    private var latestRefreshFailure: RefreshLogSnapshot? {
        refreshLogs?.first { !($0.errorMessage ?? "").isEmpty }
    }

    // One synchronous file stat per completed download is body-hostile; the
    // count is computed off the main actor in the refresh path and cached,
    // like the sync row counts and refresh logs.
    private func computeVerifiedDownloadSummary() async -> String {
        let candidates: [(fileURL: URL?, expectedByteCount: Int64)] = appModel.downloads.records
            .filter { $0.state == .completed }
            .map { record in
                (
                    record.sourceFileSHA256.isEmpty ? nil : appModel.downloads.localFileURL(for: record),
                    record.bytesReceived
                )
            }
        guard !candidates.isEmpty else {
            return "None"
        }
        let verifiedCount = await Self.verifiedDownloadCount(of: candidates)
        return "\(verifiedCount) of \(candidates.count)"
    }

    @concurrent
    private static func verifiedDownloadCount(
        of candidates: [(fileURL: URL?, expectedByteCount: Int64)]
    ) async -> Int {
        candidates.count { candidate in
            guard let fileURL = candidate.fileURL,
                  let byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber
            else {
                return false
            }
            return byteCount.int64Value == candidate.expectedByteCount
        }
    }

    private func refreshSyncDetailsNow() async {
        await appModel.syncStatus.refreshAccountStatus(force: true)
        loadSyncRowCounts()
        refreshLogs = await appModel.library.loadAllRefreshLogs()
        verifiedDownloadSummary = await computeVerifiedDownloadSummary()
    }

    private func loadSyncRowCounts() {
        do {
            subscriptionRecordCount = try modelContext.fetch(
                FetchDescriptor<SubscriptionRecord>()
            ).count
            progressRecordCount = try modelContext.fetch(
                FetchDescriptor<EpisodeProgressRecord>()
            ).count
            syncDetailsErrorMessage = nil
        } catch {
            syncDetailsErrorMessage = error.localizedDescription
        }
    }
}
