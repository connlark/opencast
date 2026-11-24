import SwiftUI

struct PodcastOpenFeedRow: View {
    let feedURL: URL
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Open Feed")
                        .font(.headline)

                    Text(feedURL.host() ?? feedURL.absoluteString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            64
        }
    }
}

#Preview("Open Feed") {
    List {
        Section {
            PodcastOpenFeedRow(feedURL: URL(string: "https://feeds.northfield.example.com/the-signal.xml")!) {}
        }
    }
}
