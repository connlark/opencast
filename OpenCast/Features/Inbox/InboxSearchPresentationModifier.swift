import SwiftUI

struct InboxSearchPresentationModifier: ViewModifier {
    let isSearchVisible: Bool
    @Binding var searchQuery: String
    @Binding var isSearchPresented: Bool
    @Binding var searchMode: EpisodeSearchMode

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSearchVisible {
            // Keep Inbox collapsed to only its toolbar search button until the user asks for search.
            content
                .searchable(text: $searchQuery, isPresented: $isSearchPresented, prompt: "Search episodes")
                .searchScopes($searchMode) {
                    EpisodeSearchScopePicker()
                }
        } else {
            content
        }
    }
}
