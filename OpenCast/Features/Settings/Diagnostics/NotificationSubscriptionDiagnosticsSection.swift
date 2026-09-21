#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation
import SwiftUI

struct NotificationSubscriptionDiagnosticsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @State private var syncResult: NotificationSubscriptionSyncDiagnosticResult?
    @State private var errorMessage: String?
    @State private var isSyncing = false
    @State private var syncTask: Task<Void, Never>?
    @State private var syncTaskID: UUID?

    private let syncService = NotificationSubscriptionSyncDiagnosticService()

    var body: some View {
        Section("Notification Subscriptions") {
            Button("Sync Notification Subscriptions", systemImage: "arrow.triangle.2.circlepath", action: sync)
                .disabled(isSyncing)

            if isSyncing {
                ProgressView("Syncing")
            }

            if let syncResult {
                LabeledContent("Sync", value: syncResult.syncStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sync, \(syncResult.syncStatus)")
                LabeledContent("Accepted", value: "\(syncResult.acceptedCount)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Accepted, \(syncResult.acceptedCount)")
                LabeledContent("Pending", value: "\(syncResult.pendingCount)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Pending, \(syncResult.pendingCount)")
                LabeledContent("Rejected", value: "\(syncResult.rejectedCount)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Rejected, \(syncResult.rejectedCount)")
                if syncResult.rejectedCount > 0 {
                    Text(syncResult.rejectedSummary)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            let healthByFeedURL = appModel.library.notificationFeedHealthByFeedURL
            if !healthByFeedURL.isEmpty {
                ForEach(healthByFeedURL.sorted(by: { $0.key < $1.key }), id: \.key) { feedURL, health in
                    LabeledContent {
                        Text(healthSummary(for: health))
                    } label: {
                        Text(feedURL)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                }
            }
        }
        .onDisappear(perform: cancel)
    }

    private func healthSummary(for health: NotificationFeedHealth) -> String {
        guard health.consecutiveFailures > 0 else {
            return "OK"
        }
        var summary = "\(health.consecutiveFailures) failures"
        if let lastError = health.lastError {
            summary += " · \(lastError)"
        }
        return summary
    }

    private func sync() {
        syncTask?.cancel()
        isSyncing = true
        errorMessage = nil
        syncResult = nil

        let taskID = UUID()
        syncTaskID = taskID
        syncTask = Task {
            defer {
                clearSyncTask(id: taskID)
            }

            do {
                syncResult = try await syncService.run(activePodcastIDs: appModel.library.activePodcastIDs)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        syncTask?.cancel()
        syncTask = nil
        syncTaskID = nil
        isSyncing = false
    }

    private func clearSyncTask(id: UUID) {
        guard syncTaskID == id else {
            return
        }

        syncTask = nil
        syncTaskID = nil
        isSyncing = false
    }
}
#endif
