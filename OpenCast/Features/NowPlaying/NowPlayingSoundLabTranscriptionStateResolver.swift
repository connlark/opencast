nonisolated enum NowPlayingSoundLabTranscriptionStateResolver {
    static func activity(
        currentEpisodeID: String,
        requestEpisodeID: String?,
        storeEpisodeID: String?
    ) -> NowPlayingSoundLabTranscriptionActivity {
        if requestEpisodeID == currentEpisodeID || storeEpisodeID == currentEpisodeID {
            return .currentEpisode
        }
        if requestEpisodeID != nil || storeEpisodeID != nil {
            return .otherEpisode
        }
        return .none
    }

    static func mode(
        preference: AdDetectionMode?,
        isRemoteSurfaceVisible: Bool,
        isRemoteAvailabilityUnknown: Bool
    ) -> NowPlayingSoundLabTranscriptionMode {
        guard preference == .cloud else {
            return .local
        }
        if isRemoteSurfaceVisible {
            return .cloud
        }
        if isRemoteAvailabilityUnknown {
            return .cloudResolving
        }
        return .local
    }
}
