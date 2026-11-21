import SwiftUI

struct AnalysisModelCardRow: View {
    let card: AnalysisModelCardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.headline)
                Text(card.providerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(card.price)
                .font(.subheadline)
            AnalysisModelCardPoints(strengths: card.strengths, weaknesses: card.weaknesses)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
