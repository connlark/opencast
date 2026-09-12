import SwiftUI

/// Shared purchase outcome and recovery rows for every surface that sells
/// transcription hours.
struct RemoteTranscriptionPurchaseStatusView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let offersRecovery: Bool

    var body: some View {
        switch appModel.remoteTranscriptionPurchases.purchasePhase {
        case .idle, .purchasing:
            EmptyView()
        case .pendingApproval:
            Label("Purchase awaiting approval", systemImage: "hourglass")
                .foregroundStyle(.secondary)
            if offersRecovery {
                Button("Refresh Purchase Status", systemImage: "arrow.clockwise", action: retryCredit)
                    .disabled(appModel.remoteTranscriptionPurchases.isRefreshing)
            }
        case .completed(let creditedSeconds):
            Label(
                "Added \(RemoteTranscriptionBalanceFormatting.hours(creditedSeconds))",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            if offersRecovery {
                Button("Retry Purchase Credit", systemImage: "arrow.clockwise", action: retryCredit)
                    .disabled(appModel.remoteTranscriptionPurchases.isRefreshing)
            }
        }
    }

    private func retryCredit() {
        Task { await appModel.remoteTranscriptionPurchases.refreshPurchases() }
    }
}
