import SwiftUI

struct EpisodeSearchPresentationModifier: ViewModifier {
    let isSearchVisible: Bool
    let prompt: String
    @Binding var searchQuery: String
    @Binding var isSearchPresented: Bool
    @Binding var searchMode: EpisodeSearchMode

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSearchVisible {
            content
                .searchable(
                    text: $searchQuery,
                    isPresented: $isSearchPresented,
                    prompt: prompt
                )
                .searchScopes($searchMode) {
                    EpisodeSearchScopePicker()
                }
        } else {
            content
        }
    }
}
