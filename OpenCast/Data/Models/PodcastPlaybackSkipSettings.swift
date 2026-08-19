import Foundation

nonisolated struct PodcastPlaybackSkipSettings: Equatable, Sendable {
    static let disabled = PodcastPlaybackSkipSettings()

    var skipIntroSeconds: TimeInterval
    var skipOutroSeconds: TimeInterval

    init(
        skipIntroSeconds: TimeInterval = 0,
        skipOutroSeconds: TimeInterval = 0
    ) {
        self.skipIntroSeconds = skipIntroSeconds
        self.skipOutroSeconds = skipOutroSeconds
    }

    var isValid: Bool {
        Self.isValid(skipIntroSeconds) && Self.isValid(skipOutroSeconds)
    }

    var sanitized: PodcastPlaybackSkipSettings {
        PodcastPlaybackSkipSettings(
            skipIntroSeconds: Self.sanitized(skipIntroSeconds),
            skipOutroSeconds: Self.sanitized(skipOutroSeconds)
        )
    }

    func mergingGreatestValid(
        with other: PodcastPlaybackSkipSettings
    ) -> PodcastPlaybackSkipSettings {
        let current = sanitized
        let other = other.sanitized
        return PodcastPlaybackSkipSettings(
            skipIntroSeconds: max(current.skipIntroSeconds, other.skipIntroSeconds),
            skipOutroSeconds: max(current.skipOutroSeconds, other.skipOutroSeconds)
        )
    }

    static func greatestValid<S: Sequence>(
        in settings: S
    ) -> PodcastPlaybackSkipSettings where S.Element == PodcastPlaybackSkipSettings {
        settings.reduce(.disabled) { merged, settings in
            merged.mergingGreatestValid(with: settings)
        }
    }

    static func isValid(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0
    }

    static func sanitized(_ value: TimeInterval) -> TimeInterval {
        isValid(value) ? value : 0
    }
}
