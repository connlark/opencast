nonisolated enum AnalysisKeyTestSubject: Equatable {
    case typed
    case saved
    case none

    static func choose(draft: String, hasSavedKey: Bool) -> AnalysisKeyTestSubject {
        if draft.contains(where: { !$0.isWhitespace }) {
            return AnalysisProviderKeyFormat.isPlausible(draft) ? .typed : .none
        }
        return hasSavedKey ? .saved : .none
    }
}
