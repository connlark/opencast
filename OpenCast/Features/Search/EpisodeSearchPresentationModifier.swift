import SwiftUI

struct EpisodeSearchPresentationModifier: ViewModifier {
    /// How long `searchable` stays attached after search is hidden: long enough for the system's
    /// dismissal to get under way, short enough that the inactive field never shows.
    private static let dismissalSettle: Duration = .milliseconds(50)

    let isSearchVisible: Bool
    let prompt: String
    @Binding var searchQuery: String
    @Binding var isSearchPresented: Bool
    @Binding var searchMode: EpisodeSearchMode
    var isFullTextSearchAvailable = true

    /// Removing `searchable` in the update that dismisses search strands the system's dismissal
    /// about one time in four: nothing moves, but an animation stays in flight for a minute.
    @State private var staysAttached = false

    func body(content: Content) -> some View {
        presentation(content)
            .task(id: isSearchVisible) {
                if isSearchVisible {
                    staysAttached = true
                    return
                }
                guard staysAttached else {
                    return
                }

                try? await Task.sleep(for: Self.dismissalSettle)
                guard !Task.isCancelled else {
                    return
                }
                staysAttached = false
            }
    }

    @ViewBuilder
    private func presentation(_ content: Content) -> some View {
        if isSearchVisible || staysAttached {
            content
                .searchable(
                    text: $searchQuery,
                    isPresented: $isSearchPresented,
                    prompt: prompt
                )
                .searchScopes($searchMode) {
                    EpisodeSearchScopePicker(
                        isFullTextAvailable: isFullTextSearchAvailable
                    )
                }
        } else {
            content
        }
    }
}
