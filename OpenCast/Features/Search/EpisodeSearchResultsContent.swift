import SwiftUI

struct EpisodeSearchResultsContent: View {
    let mode: EpisodeSearchMode
    let isLoadingVisible: Bool
    let isSearching: Bool
    let results: [EpisodeSearchResult]
    let fallbackEpisodes: [EpisodeListItemSnapshot]
    var selectsEpisodeDetailOnPlay = false
    var onSelect: () -> Void = {}
    let onOpenEpisode: (String) -> Void

    var body: some View {
        if isLoadingVisible {
            EpisodeSearchLoadingView(mode: mode)
        } else if !results.isEmpty {
            ForEach(results) { result in
                EpisodeRowButton(
                    episode: result.episode,
                    searchResult: result,
                    selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                    onSelect: onSelect,
                    onOpenEpisode: onOpenEpisode
                )
            }
        } else if isSearching {
            ForEach(fallbackEpisodes) { episode in
                EpisodeRowButton(
                    episode: episode,
                    selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                    onSelect: onSelect,
                    onOpenEpisode: onOpenEpisode
                )
            }
        } else {
            ContentUnavailableView.search
        }
    }
}
