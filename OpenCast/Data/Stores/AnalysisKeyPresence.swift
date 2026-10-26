/// Whether a provider key is saved on this device, and whether its Keychain
/// item syncs through iCloud Keychain.
nonisolated enum AnalysisKeyPresence: Equatable, Hashable, Sendable {
    case none
    case saved(synced: Bool)

    var isSaved: Bool {
        if case .saved = self { true } else { false }
    }
}

/// What this device knows about a provider's synced copy, shown or not (a
/// local key wins on read). `unknown` until a read says, and after a read
/// fails: never taken as absent.
nonisolated enum AnalysisSyncedCopyStatus: Equatable, Hashable, Sendable {
    case absent
    case present
    case unknown
}
