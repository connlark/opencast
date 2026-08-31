import OpenCastCore

struct DirectoryFeedChoicePresentation {
    let explanationTitle: String
    let explanationSystemImage: String
    let explanationBody: String
    let primaryTitle: String
    let secondaryTitle: String
    let secondaryActionTitle: String

    init(reason: DirectoryFeedChoice.Reason) {
        switch reason {
        case .fullerFeedPromoted:
            explanationTitle = "A fuller feed is available"
            explanationSystemImage = "sparkles"
            explanationBody = "Another feed for this show is up to date and carries many more episodes. The fuller feed is recommended."
            primaryTitle = "Fuller Feed"
            secondaryTitle = "Original Feed"
            secondaryActionTitle = "Use Original Feed"
        case .fullerFeedStale:
            explanationTitle = "A full archive is available"
            explanationSystemImage = "archivebox"
            explanationBody = "A fuller feed exists for this show, but it is no longer updating. The current feed stays recommended."
            primaryTitle = "Current Feed"
            secondaryTitle = "Full Archive — No Longer Updating"
            secondaryActionTitle = "Use Full Archive"
        case .fullerFeedSalvaged:
            explanationTitle = "A fuller feed was partially read"
            explanationSystemImage = "exclamationmark.triangle"
            explanationBody = "A fuller feed exists for this show, but it could not be fully read. The current feed stays recommended."
            primaryTitle = "Current Feed"
            secondaryTitle = "Fuller Feed — Partially Read"
            secondaryActionTitle = "Use Partially Read Feed"
        }
    }
}
