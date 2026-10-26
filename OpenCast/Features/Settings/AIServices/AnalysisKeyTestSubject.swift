/// Which key the key sheet's Test checks: the typed key whenever anything is
/// typed (and only if it is a whole key), else the saved key.
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
