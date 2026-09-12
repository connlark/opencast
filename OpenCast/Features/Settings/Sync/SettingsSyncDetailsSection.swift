import SwiftData
import SwiftUI

struct SettingsSyncDetailsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var subscriptionRecordCount: Int?
    @State private var progressRecordCount: Int?
    @State private var errorMessage: String?
    @State private var refreshID: UUID?

    var body: some View {
        Section("Details") {
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

            LabeledContent {
                Text(OpenCastModelContainerFactory.cloudKitContainerIdentifier)
            } label: {
                Label("CloudKit Container", systemImage: "shippingbox")
            }

            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .disabled(refreshID != nil)

            if refreshID != nil {
                ProgressView("Refreshing")
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .task {
            loadRowCounts()
        }
        .task(id: refreshID) {
            guard let refreshID else {
                return
            }
            await appModel.syncStatus.refreshAccountStatus(force: true)
            loadRowCounts()
            if self.refreshID == refreshID {
                self.refreshID = nil
            }
        }
    }

    private func refresh() {
        refreshID = UUID()
    }

    private func loadRowCounts() {
        do {
            subscriptionRecordCount = try modelContext.fetchCount(FetchDescriptor<SubscriptionRecord>())
            progressRecordCount = try modelContext.fetchCount(FetchDescriptor<EpisodeProgressRecord>())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
