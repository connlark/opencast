import SwiftUI

struct PodcastDescriptionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    let summaryHTML: String?

    var body: some View {
        let summary = summaryHTML.map { HTMLPlainText.collapsedText(from: $0) } ?? ""
        let canExpand = summary.count > 160

        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if canExpand {
                    Button(
                        isExpanded ? "Show Less" : "Show More",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down",
                        action: toggleExpanded
                    )
                    .font(.subheadline)
                    .bold()
                    .buttonStyle(.plain)
                }
            }
            .animation(reduceMotion ? nil : .smooth, value: isExpanded)
        }
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}
