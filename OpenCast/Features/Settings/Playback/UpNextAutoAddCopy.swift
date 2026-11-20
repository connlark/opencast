nonisolated enum UpNextAutoAddCopy {
    static func ruleSentence(
        limit: UpNextAutoAddLimit,
        limitReachedAction: UpNextAutoAddLimitReachedAction
    ) -> String {
        let episodeCount = limit.rawValue.formatted()
        return switch limitReachedAction {
        case .stopAdding:
            "Automatically adds new episodes to Up Next. New episodes stop being added when Up Next reaches \(episodeCount) episodes."
        case .addToTopOnly:
            "Automatically adds new episodes to Up Next. When Up Next reaches \(episodeCount) episodes, new episodes added to the top remove the last episode in the queue; shows set to the bottom wait until Up Next is below the limit."
        }
    }
}
