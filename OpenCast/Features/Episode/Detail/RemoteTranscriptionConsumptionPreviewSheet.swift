import SwiftUI

/// Pre-create consumption preview (pass 1 decision 10): the episode's
/// estimated cost against the current balance, honest overdraft copy when
/// the job would ride debt, a blocked state at zero headroom, and an inline
/// top-up that resumes the flow once credits land.
struct RemoteTranscriptionConsumptionPreviewSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let request: RemoteTranscriptionStartPreviewRequest
    let onStart: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                estimateSection
                if showsTopUp {
                    topUpSection
                }
            }
            .navigationTitle("Remote Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start)
                        .disabled(!estimate.fitsWithinHeadroom)
                }
            }
        }
        .task { await appModel.remoteTranscriptionPurchases.refreshBalance() }
        .presentationDetents([.medium, .large])
    }

    private var estimate: RemoteTranscriptionConsumptionEstimate {
        appModel.remoteTranscriptionPurchases.estimate(
            durationSeconds: request.durationSeconds ?? 0
        )
    }

    private var showsTopUp: Bool {
        guard case .available = appModel.remoteTranscriptionPurchases.availability else {
            return false
        }
        return estimate.overdraftSeconds > 0 || !estimate.fitsWithinHeadroom
    }

    private var estimateSection: some View {
        Section {
            LabeledContent("This episode") {
                Text(
                    request.durationSeconds.map {
                        RemoteTranscriptionBalanceFormatting.hours(Int64($0.rounded(.up)))
                    } ?? String(localized: "Unknown length")
                )
            }
            LabeledContent("Balance") {
                Text(RemoteTranscriptionBalanceFormatting.hours(estimate.availableSeconds))
            }
        } footer: {
            Text(footerCopy)
        }
    }

    private var topUpSection: some View {
        Section("Add Hours") {
            ForEach(appModel.remoteTranscriptionPurchases.products) { product in
                RemoteTranscriptionStorePackRow(product: product)
            }
        }
    }

    private var footerCopy: String {
        if !estimate.fitsWithinHeadroom {
            String(localized: "Not enough hours for this episode. Add hours to continue — the transcription will start once they arrive.")
        } else if estimate.overdraftSeconds > 0 {
            String(localized: "This episode runs past your balance. It will still transcribe now, and the extra time is taken out of your next purchase.")
        } else {
            String(localized: "Transcription happens on the server; hours are only charged for delivered transcripts.")
        }
    }

    private func start() {
        onStart()
        dismiss()
    }

    private func cancel() {
        appModel.remoteTranscription.store.dismissStartPreview(ifMatching: request)
        dismiss()
    }
}
