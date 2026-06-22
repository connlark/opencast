import SwiftData
import SwiftUI

struct SettingsDiagnosticsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var subscriptionRecordCount: Int?
    @State private var progressRecordCount: Int?
    @State private var syncDetailsErrorMessage: String?

    var body: some View {
        Form {
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

            Section("Refresh Logs") {
                if let latestRefreshLog = appModel.library.latestRefreshOverall {
                    RefreshLogSummaryRow(title: "Latest Refresh", log: latestRefreshLog)
                } else {
                    LabeledContent("Latest Refresh", value: "Never")
                }

                if let latestRefreshFailure = appModel.library.latestRefreshFailure {
                    RefreshLogSummaryRow(title: "Latest Failure", log: latestRefreshFailure)
                } else {
                    LabeledContent("Latest Failure", value: "None")
                }

                LabeledContent("Retained Logs", value: "\(appModel.library.refreshLogCount)")

                if !appModel.library.refreshLogs.isEmpty {
                    NavigationLink {
                        RefreshLogListView(logs: appModel.library.refreshLogs)
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

    private func refreshSyncDetails() {
        Task {
            await refreshSyncDetailsNow()
        }
    }

    private func refreshSyncDetailsNow() async {
        await appModel.syncStatus.refreshAccountStatus(force: true)
        loadSyncRowCounts()
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
