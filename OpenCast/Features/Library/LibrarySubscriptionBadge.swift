import SwiftUI

/// What the count ball on a subscription tile or row shows. The Library
/// counts new episodes per show as each cell renders, so a count change
/// re-evaluates that cell alone; the grouped Inbox already knows how many
/// episodes match its filter and hands the number in.
nonisolated enum LibrarySubscriptionBadge: Equatable, Sendable {
    case hidden
    case newEpisodes
    case episodeCount(Int)

    /// The link's spoken value for a badge showing `count`.
    func accessibilityValue(count: Int) -> Text {
        switch self {
        case .hidden, .newEpisodes:
            LibraryNewEpisodeBadge.accessibilityValue(count: count)
        case .episodeCount:
            count > 0 ? Text("^[\(count) episode](inflect: true)") : Text(verbatim: "")
        }
    }
}
