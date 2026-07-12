import SwiftUI

struct EpisodeSearchResultsContent<Row: View>: View {
    let mode: EpisodeSearchMode
    let isLoadingVisible: Bool
    let isSearching: Bool
    let results: [EpisodeSearchResult]
    let fallbackEpisodes: [EpisodeListItemSnapshot]
    @ViewBuilder let row: (EpisodeListItemSnapshot, EpisodeSearchResult?) -> Row

    var body: some View {
        if isLoadingVisible {
            EpisodeSearchLoadingView(mode: mode)
        } else if !results.isEmpty {
            ForEach(results) { result in
                row(result.episode, result)
            }
        } else if isSearching {
            ForEach(fallbackEpisodes) { episode in
                row(episode, nil)
            }
        } else {
            ContentUnavailableView.search
        }
    }
}
