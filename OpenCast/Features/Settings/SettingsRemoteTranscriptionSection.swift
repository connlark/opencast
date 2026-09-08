import OpenCastTranscription
import SwiftUI

/// Remote transcription balance + store. The section is
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
            .onDisappear(perform: dismissPurchasePhase)
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
                RemoteTranscriptionPurchaseStatusView(offersRecovery: false)
                Button("Refresh Purchases", systemImage: "arrow.clockwise", action: refreshPurchases)
                    .disabled(store.isRefreshing)
                RemoteTranscriptionRefundRequestRows(store: store)
            }
        }
    }

    private func refreshPurchases() {
        Task { await appModel.remoteTranscriptionPurchases.refreshPurchases() }
    }

    private func retryPreparation() {
        retryRequestID = UUID()
    }

    private func dismissPurchasePhase() {
        appModel.remoteTranscriptionPurchases.dismissPurchasePhase()
    }
}
