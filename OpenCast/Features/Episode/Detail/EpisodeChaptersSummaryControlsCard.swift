import SwiftUI

/// Chapters & Summary entry states on episode detail — a per-episode manual
/// action below the show notes, offered for any episode with a completed
/// transcript but no current analysis. Failures render as the ready state
/// again (fail-open — never an error surface); the one deliberate exception
/// is the pay gate's needs-minutes state, which must be discoverable and
/// carry a buy path (H8).
struct EpisodeChaptersSummaryControlsCard: View {
    enum Presentation: Equatable {
        /// The cost label is nil while the pay gate is dark or the run
        /// cannot be priced locally.
        case ready(costDescription: String?)
        case running
        /// The feed declares `podcast:chapters`: creator metadata wins, so
        /// generation is not offered and the card explains why.
        case creatorChaptersAvailable
        /// The worker refused the last run with a typed insufficient-balance
        /// denial: show the cost and the house top-up inline; the deferred
        /// run retries itself once credit lands.
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
            }
        }
    }
}
