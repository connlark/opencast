import Foundation

/// Every visible string of Make a Playlist, kept together so the menu, the
/// sheet and the tests share one wording.
nonisolated enum PlaylistOrganizerCopy {
    static let menuSectionTitle = "Apple Intelligence · Beta"
    static let menuItemTitle = "Make a Playlist…"
    static let sheetTitle = "Make a Playlist"
    static let betaSubtitle = "Beta"
    static let featureName = "Make a Playlist"
    static let fieldTitle = "What kind of playlist?"
    static let fieldPlaceholder = "Civil War episodes"
    static let suggestToggleTitle = "Suggest groups instead"
    static let askButtonTitle = "Ask"
    static let progress = "Asking Apple Intelligence…"
    static let stillWorking = "Still working…"
    static let outcomeTitle = "Couldn’t Make a Playlist"
    static let emptyTitle = "No Playlists"
    static let tryAgain = "Try Again"
    static let suggestGroupsInstead = "Suggest Groups Instead"
    static let askForPlaylistInstead = "Ask for a Playlist Instead"
    static let generatedFooter = "Generated with Apple Intelligence."
    static let helpLinkTitle = "How Make a Playlist works"
    static let sortEpisodes = "Sort Episodes"
    static let removePlaylist = "Remove Playlist"
    static let addEpisodes = "Add Episodes…"
    static let discardTitle = "Discard these playlists?"
    static let discardConfirm = "Discard Playlists"
    static let keepEditing = "Keep Editing"
    static let saveErrorTitle = "Playlist Error"
    static let proposalTitlePlaceholder = "Playlist name"

    static func saveTitle(count: Int) -> String {
        guard count > 0 else {
            return "Save"
        }
        return String(AttributedString(localized: "Save ^[\(count) Playlist](inflect: true)").characters)
    }

    static func formScope(_ scope: PlaylistOrganizerScope) -> String {
        let sent = scope.sentCount.formatted()
        let total = scope.totalCount.formatted()
        return switch scope.kind {
        case .all:
            "Looks through all \(total) episodes"
        case .newest:
            "Looks through the newest \(sent) of \(total) episodes"
        case .bestMatches:
            "Looks through the \(sent) of \(total) episodes that best match"
        }
    }

    static func resultScope(_ scope: PlaylistOrganizerScope) -> String {
        let sent = scope.sentCount.formatted()
        let total = scope.totalCount.formatted()
        return switch scope.kind {
        case .all:
            "Looked through all \(total) episodes."
        case .newest:
            "Looked through the newest \(sent) of \(total) episodes."
        case .bestMatches:
            "Looked through the \(sent) of \(total) episodes that best match your request."
        }
    }
}
