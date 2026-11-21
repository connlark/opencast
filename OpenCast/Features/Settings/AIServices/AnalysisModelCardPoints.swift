import SwiftUI

struct AnalysisModelCardPoints: View {
    let strengths: [String]
    let weaknesses: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(strengths.indices, id: \.self) { index in
                Label(strengths[index], systemImage: "plus.circle")
                    .accessibilityLabel(AIServicesCopy.strength(strengths[index]))
            }
            ForEach(weaknesses.indices, id: \.self) { index in
                Label(weaknesses[index], systemImage: "minus.circle")
                    .accessibilityLabel(AIServicesCopy.weakness(weaknesses[index]))
            }
        }
        .font(.subheadline)
        .labelStyle(.titleAndIcon)
        // A form row sized its height before this wrapped, truncating a two-line point.
        .fixedSize(horizontal: false, vertical: true)
    }
}
