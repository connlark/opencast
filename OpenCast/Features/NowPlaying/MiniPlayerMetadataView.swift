import SwiftUI

struct MiniPlayerMetadataView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let podcastTitle: String

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // The system accessory has a fixed height. A scaled single
                // line stays readable; VoiceOver receives both full titles.
                Text("\(title), \(podcastTitle)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(podcastTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
