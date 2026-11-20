import SwiftUI

/// Each hosting stack writes through its own `TwoPaneRootWriter`, so an outgoing
/// container or obsolete detail stack never overwrites a newer path. The visit
/// ledger lives above both containers, so a switch keeps what a visit changed.
struct TwoPaneRoot<Root: View>: View {
    @State private var visitState = TwoPaneRootVisitState()

    let section: AppSection
    /// The scene's current container; the writers read it live.
    @Binding var container: TwoPaneRootContainer
    @Binding var path: [AppRoute]
    let placeholder: TwoPaneRootPlaceholder
    let openFromRoot: (AppRoute) -> Void
    let onOpenEpisode: (String) -> Void
    let onOpenPlaylist: (String) -> Void
    @ViewBuilder let root: () -> Root

    var body: some View {
        Group {
            switch container {
            case .split:
                split
            case .stack:
                TwoPaneRootStackHost(
                    section: section,
                    container: $container,
                    path: $path,
                    visitState: visitState,
                    onOpenEpisode: onOpenEpisode,
                    onOpenPlaylist: onOpenPlaylist,
                    root: root
                )
            }
        }
        .onChange(of: path, initial: true) { _, path in
            visitState.retainVisits(in: path)
        }
    }

    private var split: some View {
        let head = TwoPaneRootPath.head(of: path)
        return NavigationSplitView(columnVisibility: .constant(.all)) {
            root()
                .environment(
                    \.twoPaneRootSidebar,
                    TwoPaneRootSidebar(selectedRoute: head, activate: openFromRoot)
                )
                // Both columns stay shown in this container, so the system's
                // sidebar toggle would have nothing to do.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            TwoPaneRootDetailHost(
                section: section,
                head: head,
                container: $container,
                path: $path,
                visitState: visitState,
                placeholder: placeholder,
                onOpenEpisode: onOpenEpisode,
                onOpenPlaylist: onOpenPlaylist
            )
            // A new head is a new detail stack: the page it shows is the
            // complete route (an Inbox override included), not the screen.
            .id(head)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct TwoPaneRootStackHost<Root: View>: View {
    @State private var token = TwoPaneRootWriterToken()

    let section: AppSection
    @Binding var container: TwoPaneRootContainer
    @Binding var path: [AppRoute]
    let visitState: TwoPaneRootVisitState
    let onOpenEpisode: (String) -> Void
    let onOpenPlaylist: (String) -> Void
    let root: () -> Root

    var body: some View {
        let writer = TwoPaneRootWriter.make(
            .stack,
            token: token,
            path: $path,
            container: $container,
            section: section.rawValue
        )
        NavigationStack(path: writer.stackPath) {
            root()
                .withOpenCastDestinations(onOpenEpisode: onOpenEpisode, onOpenPlaylist: onOpenPlaylist)
        }
        .environment(\.twoPaneRootVisit, writer.visitScope(visitState))
    }
}

private struct TwoPaneRootDetailHost: View {
    @State private var token = TwoPaneRootWriterToken()

    let section: AppSection
    let head: AppRoute?
    @Binding var container: TwoPaneRootContainer
    @Binding var path: [AppRoute]
    let visitState: TwoPaneRootVisitState
    let placeholder: TwoPaneRootPlaceholder
    let onOpenEpisode: (String) -> Void
    let onOpenPlaylist: (String) -> Void

    var body: some View {
        let writer = TwoPaneRootWriter.make(
            .detail(head: head),
            token: token,
            path: $path,
            container: $container,
            section: section.rawValue
        )
        NavigationStack(path: writer.detailSuffix) {
            TwoPaneRootDetailRoot(
                route: head,
                placeholder: placeholder,
                onOpenEpisode: onOpenEpisode,
                onOpenPlaylist: onOpenPlaylist,
                close: head.map { writer.closeAction(for: $0) }
            )
            .withOpenCastDestinations(onOpenEpisode: onOpenEpisode, onOpenPlaylist: onOpenPlaylist)
        }
        .environment(\.twoPaneRootVisit, writer.visitScope(visitState))
        .twoPaneRootClearanceProbe("detail-\(section.rawValue)")
    }
}
