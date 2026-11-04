import SwiftUI

/// What a split's detail column shows when its section's path is empty.
enum TwoPaneRootPlaceholder {
    case library
    case inbox
    case upNext

    var title: String {
        switch self {
        case .library, .inbox:
            "No Show Selected"
        case .upNext:
            "No Episode Selected"
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            "square.stack"
        case .inbox:
            "tray"
        case .upNext:
            "text.line.first.and.arrowtriangle.forward"
        }
    }

    var description: String {
        switch self {
        case .library:
            "Choose a show in the Library."
        case .inbox:
            "Choose a show in the Inbox."
        case .upNext:
            "Choose an episode in Up Next."
        }
    }
}

/// The root of a split's detail stack: the page for the path's head, through
/// the same destination switch the stacks use, or the placeholder. Only this
/// root gets the close action; the pages pushed above it keep `dismiss`.
struct TwoPaneRootDetailRoot: View {
    let route: AppRoute?
    let placeholder: TwoPaneRootPlaceholder
    let onOpenEpisode: (String) -> Void
    let onOpenPlaylist: (String) -> Void
    let close: TwoPaneRootCloseAction?

    var body: some View {
        if let route {
            RouteDestinationView(route: route, onOpenEpisode: onOpenEpisode, onOpenPlaylist: onOpenPlaylist)
                .environment(\.twoPaneRootClose, close)
        } else {
            ContentUnavailableView(
                placeholder.title,
                systemImage: placeholder.systemImage,
                description: Text(placeholder.description)
            )
            .accessibilityIdentifier("Two-Pane Root Placeholder")
        }
    }
}
