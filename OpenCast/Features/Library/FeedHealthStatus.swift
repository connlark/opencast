import Foundation

nonisolated struct FeedHealthStatus: Equatable {
    enum Kind: Equatable {
        case neverRefreshed
        case healthy
        case partial
        case failingSince(Date)
        case neverSucceeded
    }

    var kind: Kind
    /// The latest refresh attempt, success or not.
    var lastCheckedAt: Date?
    /// When the cached show details or any of its episodes last changed.
    var lastContentChangeAt: Date?

    static func derive(
        latestLog: RefreshLogSnapshot?,
        latestSuccessAt: Date?,
        contentChangedAt: Date?
    ) -> FeedHealthStatus {
        guard let latestLog else {
            return FeedHealthStatus(
                kind: .neverRefreshed,
                lastCheckedAt: nil,
                lastContentChangeAt: contentChangedAt
            )
        }

        let kind: Kind
        if latestLog.errorMessage?.isEmpty ?? true {
            kind = .healthy
        } else if latestLog.errorMessage?.hasPrefix(RefreshLogSnapshot.partialFeedSalvageMessage) == true {
            kind = .partial
        } else if let latestSuccessAt {
            kind = .failingSince(latestSuccessAt)
        } else {
            kind = .neverSucceeded
        }
        return FeedHealthStatus(
            kind: kind,
            lastCheckedAt: latestLog.finishedAt ?? latestLog.startedAt,
            lastContentChangeAt: contentChangedAt
        )
    }

    var isDegraded: Bool {
        switch kind {
        case .partial, .failingSince, .neverSucceeded:
            true
        case .neverRefreshed, .healthy:
            false
        }
    }

    /// A failing feed's "Refreshed X ago" would read as success, so its status line replaces it.
    var replacesRefreshedLine: Bool {
        switch kind {
        case .failingSince, .neverSucceeded:
            true
        case .neverRefreshed, .healthy, .partial:
            false
        }
    }

    var statusLine: String? {
        switch kind {
        case .neverRefreshed, .healthy:
            nil
        case .partial:
            "Partial feed loaded"
        case .failingSince(let date):
            "Hasn't refreshed since \(date.formatted(.relative(presentation: .named)))"
        case .neverSucceeded:
            "Refresh has never succeeded"
        }
    }

    var checkedUpdatedLine: String? {
        guard let lastCheckedAt else {
            return nil
        }
        var line = "Checked \(lastCheckedAt.formatted(.relative(presentation: .named)))"
        if let lastContentChangeAt {
            line += " · Updated \(lastContentChangeAt.formatted(.relative(presentation: .named)))"
        }
        return line
    }
}
