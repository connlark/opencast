import Foundation

/// Pure derivation of a feed's health copy from the per-feed refresh-log
/// projection the store already carries; view-layer only.
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
    /// When the feed's content last actually changed (`podcast_cache.updated_at`).
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
        } else if latestLog.errorMessage == RefreshLogSnapshot.partialFeedSalvageMessage {
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

    /// True when the status line supersedes the routine "Refreshed X ago"
    /// copy — a failing feed's recency would otherwise read as success.
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

    /// "Checked X ago · Updated Y ago": polling recency versus content
    /// recency, which post-Phase-6-C are genuinely different timestamps.
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
