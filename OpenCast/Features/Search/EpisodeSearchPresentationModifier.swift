import SwiftUI

struct EpisodeSearchPresentationModifier: ViewModifier {
    /// How long `searchable` stays attached after search is hidden. What
    /// matters is that it is not removed in the update that dismisses
    /// search; a beat is enough for the system's dismissal to get under way,
    /// and short enough that the inactive field never shows.
    private static let dismissalSettle: Duration = .milliseconds(50)

    let isSearchVisible: Bool
    let prompt: String
    @Binding var searchQuery: String
    @Binding var isSearchPresented: Bool
    @Binding var searchMode: EpisodeSearchMode
    var isFullTextSearchAvailable = true

    /// True from the moment search is shown until just after it is hidden.
    /// Attaching `searchable` is a different branch of this view, so taking
    /// it away rebuilds the content. Doing that in the same update that
    /// dismisses search strands the system's dismissal transition about one
    /// time in four: nothing moves on screen, but the app keeps reporting an
    /// animation in flight for a minute or more (and UI tests wait it out,
    /// sixty seconds per tap).
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
