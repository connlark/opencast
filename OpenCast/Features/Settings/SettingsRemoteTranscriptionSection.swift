import OpenCastTranscription
import SwiftUI

/// Remote transcription balance + store (pass 1 decision 10). The section is
/// always discoverable; unresolved StoreKit identity provides a retry action,
/// while actual remote and purchase actions remain gated.
struct SettingsRemoteTranscriptionSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var retryRequestID: UUID?

    var body: some View {
        section
            .task { await appModel.remoteTranscriptionPurchases.prepare() }
            .task(id: retryRequestID) {
                guard let retryRequestID else { return }
                await appModel.remoteTranscriptionPurchases.retryPreparation()
                if self.retryRequestID == retryRequestID {
                    self.retryRequestID = nil
                }
            }
    }

    private var section: some View {
        let store = appModel.remoteTranscriptionPurchases
        return Section("Remote Transcription") {
            if let balance = store.balance {
                LabeledContent("Balance") {
                    Text(RemoteTranscriptionBalanceFormatting.hours(balance.availableSeconds))
                }
                if balance.debtSeconds > 0 {
                    LabeledContent("Owed") {
                        Text(RemoteTranscriptionBalanceFormatting.hours(balance.debtSeconds))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            switch store.availability {
            case .unknown:
                LabeledContent("Availability") {
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                }
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try Again", systemImage: "arrow.clockwise", action: retryPreparation)
                    .disabled(retryRequestID != nil)
            case .storeDisabled(let reason):
                LabeledContent("Store") {
                    Text(reason)
                        .foregroundStyle(.secondary)
                }
            case .available:
                ForEach(store.products) { product in
                    RemoteTranscriptionStorePackRow(product: product)
                }
                purchasePhaseRow
                Button("Refresh Purchases", systemImage: "arrow.clockwise", action: refreshPurchases)
                    .disabled(store.isRefreshing)
                RemoteTranscriptionRefundRequestRows(store: store)
            }
        }
    }

    @ViewBuilder
    private var purchasePhaseRow: some View {
        switch appModel.remoteTranscriptionPurchases.purchasePhase {
        case .idle, .purchasing:
            EmptyView()
        case .pendingApproval:
            Label("Purchase awaiting approval", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .completed(let creditedSeconds):
            Label(
                "Added \(RemoteTranscriptionBalanceFormatting.hours(creditedSeconds))",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private func refreshPurchases() {
        Task { await appModel.remoteTranscriptionPurchases.refreshPurchases() }
    }

    private func retryPreparation() {
        retryRequestID = UUID()
    }
}
