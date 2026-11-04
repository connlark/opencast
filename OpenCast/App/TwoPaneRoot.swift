import SwiftUI

/// A section's root content in the container `TwoPaneRootRule` picks, over
/// the section's `AppNavigationPaths` slot, which is its only navigation
/// state (`TwoPaneRootPath`):
///
/// - `.split`: a `NavigationSplitView` with both columns always shown, the
///   system's column widths and `.balanced`. The root content is the
///   sidebar; its own links and callbacks open their route as the detail's
///   root (`TwoPaneRootSidebar`, `openFromRoot`). The detail is a stack whose
///   root is the page for the path's head, identified by that complete
///   route, with the rest of the path pushed on it and the shared
///   destinations inside it, so pages navigate as they do today.
/// - `.stack`: today's `NavigationStack(path:)` over the root content.
///
/// Each hosting stack writes through its own `TwoPaneRootWriter`, so an
/// outgoing container or an obsolete detail stack never overwrites a newer
/// path. The section's visit ledger lives here, above both containers, so a
/// switch rebuilds the pages without undoing what a visit changed.
struct TwoPaneRoot<Root: View>: View {
    @State private var visitState = TwoPaneRootVisitState()

    let section: AppSection
    /// The scene's current container; the writers read it live.
    @Binding var container: TwoPaneRootContainer
    @Binding var path: [AppRoute]
    let placeholder: TwoPaneRootPlaceholder
    /// Opens a route from the root content: the tab root's
    /// `openFromRoot`, which replaces the path in the split and pushes in the
    /// stack. The sidebar's links use it.
    let openFromRoot: (AppRoute) -> Void
    /// The destinations' own callbacks: pages push, in both containers.
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

/// The stack container: today's `NavigationStack` over the root content,
/// writing through its own writer.
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

/// One split detail stack, built for one head: its root page (or the
/// placeholder) with the rest of the path pushed on it.
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
        // The detail column is a viewport the shell did not have: its pages
        // take the accessory clearance from their own scroll views; this
        // records the column against the accessory.
        .twoPaneRootClearanceProbe("detail-\(section.rawValue)")
    }
}
