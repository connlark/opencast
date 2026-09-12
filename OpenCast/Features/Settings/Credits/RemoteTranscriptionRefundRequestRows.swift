import StoreKit
import SwiftUI

struct RemoteTranscriptionRefundRequestRows: View {
    let store: RemoteTranscriptionPurchaseStore

    @State private var statusMessage: String?

    var body: some View {
        DisclosureGroup("Request a Refund") {
            if store.refundCandidates.isEmpty {
                Text("No refundable purchases")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.refundCandidates) { candidate in
                Button {
                    requestRefund(candidate)
                } label: {
                    LabeledContent(displayName(for: candidate.productID)) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Purchased")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                candidate.purchaseDate,
                                format: .dateTime
                                    .year()
                                    .month(.abbreviated)
                                    .day()
                                    .hour()
                                    .minute()
                                    .second()
                            )
                        }
                    }
                }
                .tint(.primary)
            }
            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await store.refreshRefundCandidates() }
    }

    private func requestRefund(_ candidate: RemoteTranscriptionRefundCandidate) {
        Task {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            else {
                statusMessage = String(localized: "Refunds aren’t available right now.")
                return
            }
            do {
                let status = try await Transaction.beginRefundRequest(for: candidate.id, in: scene)
                if status == .success {
                    store.markRefundRequested(transactionID: candidate.id)
                    statusMessage = String(localized: "Refund requested.")
                } else {
                    statusMessage = String(localized: "Refund request dismissed.")
                }
                await store.refreshRefundCandidates()
            } catch {
                statusMessage = String(localized: "Refund request failed: \(error.localizedDescription)")
            }
        }
    }

    private func displayName(for productID: String) -> String {
        store.products.first(where: { $0.id == productID })?.displayName ?? productID
    }
}
