import Testing
@testable import OpenCast

@Suite("Sound Lab transcription row model")
struct NowPlayingSoundLabTranscriptionRowModelTests {
    @Test("A completed transcript wins over every mode and activity", arguments: [
        NowPlayingSoundLabTranscriptionMode.local,
        .cloudResolving,
        .cloud,
    ], [
        NowPlayingSoundLabTranscriptionActivity.none,
        .currentEpisode,
        .otherEpisode,
    ])
    func completedTranscriptWins(
        mode: NowPlayingSoundLabTranscriptionMode,
        activity: NowPlayingSoundLabTranscriptionActivity
    ) {
        let model = makeModel(
            hasCompletedTranscript: true,
            mode: mode,
            remoteActivity: activity,
            localActivity: activity
        )

        #expect(model.action == .showTranscript)
        #expect(model.title == "Show Transcript")
        #expect(model.systemImage == "text.quote")
        #expect(model.phase == .completed)
        #expect(model.isEnabled)
        #expect(model.accessibilityValue == "Transcript available")
    }

    @Test("Local mode offers on-device transcription")
    func localModeIsIdle() {
        assertLocalIdle(makeModel(mode: .local))
    }

    @Test("Cloud availability resolution disables the remote action")
    func cloudResolvingIsChecking() {
        let model = makeModel(mode: .cloudResolving)

        #expect(model.action == .transcribe)
        #expect(model.title == "Transcribe Remotely")
        #expect(model.systemImage == "cloud")
        #expect(model.phase == .checking)
        #expect(!model.isEnabled)
        #expect(model.accessibilityValue == "Checking remote transcription availability")
    }

    @Test("Cloud mode offers remote transcription")
    func cloudModeIsIdle() {
        assertCloudIdle(makeModel(mode: .cloud))
    }

    @Test("Current remote activity overrides local mode")
    func currentRemoteOverridesLocalMode() {
        let model = makeModel(mode: .local, remoteActivity: .currentEpisode)

        #expect(model.action == .transcribe)
        #expect(model.title == "Transcribe Remotely")
        #expect(model.phase == .running)
        #expect(!model.isEnabled)
        #expect(model.accessibilityValue == "Remote transcription in progress")
    }

    @Test("Current local activity overrides cloud mode")
    func currentLocalOverridesCloudMode() {
        let model = makeModel(mode: .cloud, localActivity: .currentEpisode)

        #expect(model.action == .transcribeLocally)
        #expect(model.title == "Transcribe")
        #expect(model.phase == .running)
        #expect(!model.isEnabled)
        #expect(model.accessibilityValue == "Transcription in progress")
    }

    @Test("Another remote request disables only cloud mode")
    func otherRemoteDisablesOnlyCloudMode() {
        let cloud = makeModel(mode: .cloud, remoteActivity: .otherEpisode)
        #expect(!cloud.isEnabled)
        #expect(cloud.accessibilityValue == "Another remote transcription is in progress")

        assertLocalIdle(makeModel(mode: .local, remoteActivity: .otherEpisode))
    }

    @Test("Another local request disables only local mode")
    func otherLocalDisablesOnlyLocalMode() {
        let local = makeModel(mode: .local, localActivity: .otherEpisode)
        #expect(!local.isEnabled)
        #expect(local.accessibilityValue == "Another transcription is in progress")

        assertCloudIdle(makeModel(mode: .cloud, localActivity: .otherEpisode))
    }

    @Test("The accessibility identifier is stable across every presentation")
    func accessibilityIdentifierIsStable() {
        for completed in [false, true] {
            for mode in [
                NowPlayingSoundLabTranscriptionMode.local,
                .cloudResolving,
                .cloud,
            ] {
                for activity in [
                    NowPlayingSoundLabTranscriptionActivity.none,
                    .currentEpisode,
                    .otherEpisode,
                ] {
                    let model = makeModel(
                        hasCompletedTranscript: completed,
                        mode: mode,
                        remoteActivity: activity,
                        localActivity: activity
                    )

                    #expect(model.accessibilityIdentifier
                        == "Now Playing Sound Lab Transcript Action")
                }
            }
        }
    }

    private func makeModel(
        hasCompletedTranscript: Bool = false,
        mode: NowPlayingSoundLabTranscriptionMode,
        remoteActivity: NowPlayingSoundLabTranscriptionActivity = .none,
        localActivity: NowPlayingSoundLabTranscriptionActivity = .none
    ) -> NowPlayingSoundLabTranscriptionRowModel {
        NowPlayingSoundLabTranscriptionRowModel(
            hasCompletedTranscript: hasCompletedTranscript,
            mode: mode,
            remoteActivity: remoteActivity,
            localActivity: localActivity
        )
    }

    private func assertLocalIdle(
        _ model: NowPlayingSoundLabTranscriptionRowModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(model.action == .transcribeLocally, sourceLocation: sourceLocation)
        #expect(model.title == "Transcribe", sourceLocation: sourceLocation)
        #expect(model.systemImage == "waveform", sourceLocation: sourceLocation)
        #expect(model.phase == .idle, sourceLocation: sourceLocation)
        #expect(model.isEnabled, sourceLocation: sourceLocation)
        #expect(model.accessibilityValue.isEmpty, sourceLocation: sourceLocation)
    }

    private func assertCloudIdle(
        _ model: NowPlayingSoundLabTranscriptionRowModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(model.action == .transcribe, sourceLocation: sourceLocation)
        #expect(model.title == "Transcribe Remotely", sourceLocation: sourceLocation)
        #expect(model.systemImage == "cloud", sourceLocation: sourceLocation)
        #expect(model.phase == .idle, sourceLocation: sourceLocation)
        #expect(model.isEnabled, sourceLocation: sourceLocation)
        #expect(model.accessibilityValue.isEmpty, sourceLocation: sourceLocation)
    }
}

@Suite("Sound Lab transcription state resolver")
struct NowPlayingSoundLabTranscriptionStateResolverTests {
    @Test("Request-only activity covers download and model preparation")
    func requestOnlyActivity() {
        #expect(resolveActivity(requestEpisodeID: "current") == .currentEpisode)
    }

    @Test("Direct store-only activity is authoritative")
    func storeOnlyActivity() {
        #expect(resolveActivity(storeEpisodeID: "current") == .currentEpisode)
    }

    @Test("Request and store can consistently name the current episode")
    func bothSourcesNameCurrentEpisode() {
        #expect(resolveActivity(requestEpisodeID: "current", storeEpisodeID: "current") == .currentEpisode)
    }

    @Test("Current activity wins over inconsistent other activity")
    func currentWinsOverOther() {
        #expect(resolveActivity(requestEpisodeID: "other", storeEpisodeID: "current") == .currentEpisode)
    }

    @Test("Any non-current source resolves to other episode")
    func otherEpisodeActivity() {
        #expect(resolveActivity(requestEpisodeID: "other") == .otherEpisode)
    }

    @Test("No active sources resolves to none")
    func noActivity() {
        #expect(resolveActivity() == .none)
    }

    @Test("Cloud preference with unknown availability resolves checking")
    func cloudUnknownResolvesChecking() {
        #expect(resolveMode(preference: .cloud, unknown: true) == .cloudResolving)
    }

    @Test("Resolved hidden cloud surface falls back to local")
    func hiddenResolvedSurfaceFallsBackToLocal() {
        #expect(resolveMode(preference: .cloud) == .local)
    }

    @Test("A synchronously visible developer surface resolves cloud")
    func devVisibleSurfaceResolvesCloud() {
        #expect(resolveMode(preference: .cloud, visible: true, unknown: true) == .cloud)
    }

    @Test("Ask and on-device preferences remain local", arguments: [
        Optional<AdDetectionMode>.none,
        .some(.onDevice),
    ])
    func nonCloudPreferencesRemainLocal(preference: AdDetectionMode?) {
        #expect(resolveMode(preference: preference, visible: true, unknown: true) == .local)
    }

    private func resolveActivity(
        requestEpisodeID: String? = nil,
        storeEpisodeID: String? = nil
    ) -> NowPlayingSoundLabTranscriptionActivity {
        NowPlayingSoundLabTranscriptionStateResolver.activity(
            currentEpisodeID: "current",
            requestEpisodeID: requestEpisodeID,
            storeEpisodeID: storeEpisodeID
        )
    }

    private func resolveMode(
        preference: AdDetectionMode?,
        visible: Bool = false,
        unknown: Bool = false
    ) -> NowPlayingSoundLabTranscriptionMode {
        NowPlayingSoundLabTranscriptionStateResolver.mode(
            preference: preference,
            isRemoteSurfaceVisible: visible,
            isRemoteAvailabilityUnknown: unknown
        )
    }
}
