#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation
import SwiftUI

struct NotificationSubscriptionDiagnosticsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @State private var syncResult: NotificationSubscriptionSyncDiagnosticResult?
    @State private var pollResult: NotificationPollSubscriptionsDiagnosticResult?
    @State private var errorMessage: String?
    @State private var isSyncing = false
    @State private var isPolling = false
    @State private var syncTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    @State private var syncTaskID: UUID?
    @State private var pollTaskID: UUID?

    private let syncService = NotificationSubscriptionSyncDiagnosticService()
    private let pollService = NotificationPollSubscriptionsDiagnosticService()

    var body: some View {
        Section("Notification Subscriptions") {
            Button("Sync Notification Subscriptions", systemImage: "arrow.triangle.2.circlepath", action: sync)
                .disabled(isSyncing || isPolling)

            Button("Poll Synced Feeds", systemImage: "antenna.radiowaves.left.and.right", action: poll)
                .disabled(isSyncing || isPolling)

            if isSyncing {
                ProgressView("Syncing")
            }

            if isPolling {
                ProgressView("Polling")
            }

            if let syncResult {
                LabeledContent("Sync", value: syncResult.syncStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sync, \(syncResult.syncStatus)")
                LabeledContent("Accepted", value: "\(syncResult.acceptedCount)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Accepted, \(syncResult.acceptedCount)")
                LabeledContent("Rejected", value: "\(syncResult.rejectedCount)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Rejected, \(syncResult.rejectedCount)")
                if syncResult.rejectedCount > 0 {
                    Text(syncResult.rejectedSummary)
                        .foregroundStyle(.secondary)
                }
            }

            if let pollResult {
                LabeledContent("Poll", value: pollResult.pollStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Poll, \(pollResult.pollStatus)")
                LabeledContent("Feeds Polled", value: "\(pollResult.feedsPolled)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Feeds Polled, \(pollResult.feedsPolled)")
                LabeledContent("Feeds Changed", value: "\(pollResult.feedsChanged)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Feeds Changed, \(pollResult.feedsChanged)")
                LabeledContent("Notifications Attempted", value: "\(pollResult.notificationsAttempted)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Notifications Attempted, \(pollResult.notificationsAttempted)")
                LabeledContent("APNs 200", value: "\(pollResult.apns200Count)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("APNs 200, \(pollResult.apns200Count)")
                LabeledContent("Deduped", value: "\(pollResult.dedupedCount)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Deduped, \(pollResult.dedupedCount)")
                if let firstError = pollResult.firstError {
                    Label(firstError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: cancel)
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

    private func poll() {
        pollTask?.cancel()
        isPolling = true
        errorMessage = nil
        pollResult = nil

        let taskID = UUID()
        pollTaskID = taskID
        pollTask = Task {
            defer {
                clearPollTask(id: taskID)
            }

            do {
                pollResult = try await pollService.run()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        syncTask?.cancel()
        pollTask?.cancel()
        syncTask = nil
        pollTask = nil
        syncTaskID = nil
        pollTaskID = nil
        isSyncing = false
        isPolling = false
    }

    private func clearSyncTask(id: UUID) {
        guard syncTaskID == id else {
            return
        }

        syncTask = nil
        syncTaskID = nil
        isSyncing = false
    }

    private func clearPollTask(id: UUID) {
        guard pollTaskID == id else {
            return
        }

        pollTask = nil
        pollTaskID = nil
        isPolling = false
    }
}
#endif
