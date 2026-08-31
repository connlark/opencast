import SwiftUI

/// Generated episode summary on episode detail — native text only, clearly
/// labeled as generated.
struct EpisodeGeneratedSummaryCard: View {
    @State private var isExpanded = false

    let summary: EpisodeTranscriptAnalysisSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Summary", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                GeneratedContentTag()
            }

            if !summary.oneLineDescription.isEmpty {
                Text(summary.oneLineDescription)
                    .font(.subheadline)
                    .bold()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(summary.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            Button(
                isExpanded ? "Show Less" : "Show More",
                systemImage: isExpanded ? "chevron.up" : "chevron.down",
                action: toggleExpanded
            )
            .font(.subheadline)
            .bold()
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}
