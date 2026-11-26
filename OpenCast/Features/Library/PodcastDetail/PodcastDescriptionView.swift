import SwiftUI

struct PodcastDescriptionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var isTruncated = false

    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onPreferenceChange(Text.LayoutKey.self, perform: noteTruncation)

                    if isTruncated {
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
    }

    private func noteTruncation(_ layouts: [Text.LayoutKey.AnchoredLayout]) {
        if !isExpanded {
            isTruncated = layouts.contains { $0.layout.isTruncated }
        }
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}
