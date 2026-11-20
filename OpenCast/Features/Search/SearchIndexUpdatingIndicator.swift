import SwiftUI

struct SearchIndexUpdatingIndicator: View {
    var mode: EpisodeSearchMode = .episodes

    private var message: String {
        switch mode {
        case .episodes:
            "Search index updating — showing title matches only"
        case .fullText:
            "Full Text is temporarily unavailable while the search index updates — showing title matches only"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Search Index Updating")
    }
}

#Preview("Search Index Updating") {
    List {
        SearchIndexUpdatingIndicator()
        SearchIndexUpdatingIndicator(mode: .fullText)
    }
}
