import SwiftUI

/// One purchasable credit pack: localized name/price from StoreKit, grant
/// from the verified catalog.
struct RemoteTranscriptionStorePackRow: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let product: RemoteTranscriptionStoreProduct

    var body: some View {
        LabeledContent {
            Button(action: purchase) {
                if isPurchasing {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isPurchasing)
            .accessibilityLabel("Buy \(product.displayName) for \(product.displayPrice)")
        } label: {
            Text(product.displayName)
            Text(RemoteTranscriptionBalanceFormatting.hours(product.grantSeconds))
                .foregroundStyle(.secondary)
        }
    }

    private var isPurchasing: Bool {
        appModel.remoteTranscriptionPurchases.purchasePhase == .purchasing(productID: product.id)
    }

    private func purchase() {
        Task { await appModel.remoteTranscriptionPurchases.purchase(product) }
    }
}
