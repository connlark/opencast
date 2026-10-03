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
    static let showPickerTitle = "Choose a Show"
    static let showPickerSubtitle = "Make a Playlist · Beta"
    static let showPickerSearchPrompt = "Shows"
    static let showPickerFooter = "Playlists are drafted from one show’s episodes. A show needs at least \(PlaylistOrganizerFeatureFlags.minimumEpisodeCount) episodes."
    static let showPickerEmptyTitle = "No Shows"
    static let showPickerEmptyMessage = "Subscribe to a show, then make a playlist from its episodes."
    static let ineligibleShowHint = "Needs at least \(PlaylistOrganizerFeatureFlags.minimumEpisodeCount) episodes"

    /// The organizer's subtitle names its show, the shape Recap and Ask use.
    static func subtitle(showTitle: String?) -> String {
        let trimmed = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return betaSubtitle
        }
        return "\(trimmed) · Beta"
    }

    static func episodeCount(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) episode](inflect: true)").characters)
    }

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
