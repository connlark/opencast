nonisolated enum AnalysisKeyPresence: Equatable, Hashable, Sendable {
    case none
    case saved(synced: Bool)

    var isSaved: Bool {
        if case .saved = self { true } else { false }
    }
}

/// `unknown` until a read says, and after a failed read; never taken as absent.
nonisolated enum AnalysisSyncedCopyStatus: Equatable, Hashable, Sendable {
    case absent
    case present
    case unknown
}
