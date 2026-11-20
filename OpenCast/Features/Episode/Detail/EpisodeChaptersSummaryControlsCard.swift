import SwiftUI

struct EpisodeChaptersSummaryControlsCard: View {
    enum Presentation: Equatable {
        /// Nil while the pay gate is dark or the run cannot be priced locally.
        case ready(costDescription: String?)
        case running
        case creatorChaptersAvailable
        case needsMinutes(chargeDescription: String)
    }

    @Environment(OpenCastAppModel.self) private var appModel

    let presentation: Presentation
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Chapters & Summary", systemImage: "list.bullet.rectangle")
                .font(.headline)

            switch presentation {
            case .ready(let costDescription):
                Button("Generate Chapters & Summary", systemImage: "sparkles", action: onGenerate)
                    .buttonStyle(.glass)
                if let costDescription {
                    Text(costDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .running:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Generating chapters and a summary…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .creatorChaptersAvailable:
                Text("This show publishes its own chapters for this episode, so OpenCast doesn’t generate them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .needsMinutes(let chargeDescription):
                Text(chargeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                addHoursSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .task(id: presentation) {
            if case .needsMinutes = presentation {
                await appModel.remoteTranscriptionPurchases.prepare()
            }
        }
    }

    @ViewBuilder
    private var addHoursSection: some View {
        let products = appModel.remoteTranscriptionPurchases.products
        if !products.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Hours")
                    .font(.subheadline)
                    .bold()
                ForEach(products) { product in
                    RemoteTranscriptionStorePackRow(product: product)
                }
                RemoteTranscriptionPurchaseStatusView(offersRecovery: true)
            }
        }
    }
}
