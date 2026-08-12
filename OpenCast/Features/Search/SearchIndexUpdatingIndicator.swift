import SwiftUI

/// Unobtrusive row explaining that results currently come from the bounded
/// title/podcast-title fallback because the derived search index is not ready.
/// Surfaces show it only while `EpisodeSearchSession.isIndexedSearchUnavailable`
/// is set; it disappears as soon as the index answers again. In the Full Text
/// scope it also carries the scope-unavailability affordance, because the
/// scope bar cannot restyle an active segment.
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
    }
}

#Preview("Search Index Updating") {
    List {
        SearchIndexUpdatingIndicator()
        SearchIndexUpdatingIndicator(mode: .fullText)
    }
}
