import XCTest

final class OpenCastUITests: XCTestCase {
    // Keep these in sync with OpenCastUITestSeedData episode/feed IDs and the row identifier helpers.
    private static let seededEpisodeRowIdentifier = "episode-row-ui-test-episode-1"
    private static let seededCompletedEpisodeRowIdentifier = "episode-row-ui-test-episode-completed"
    private static let seededSubscriptionRowIdentifier = "subscription-row-https://example.com/ui-test-feed.xml"
    private static let seedVoiceBoostModeEnvironmentKey = "OPENCAST_SEED_VOICE_BOOST_MODE"
    private static let perEpisodeVoiceBoostModeValue = "perEpisode"
    private static let playEpisodeTraceArmingSecondsEnvironmentKey = "OPENCAST_PLAY_EPISODE_TRACE_ARMING_SECONDS"
    private static let seededPeelTraceArmingSecondsEnvironmentKey = "OPENCAST_SEEDED_PEEL_TRACE_ARMING_SECONDS"
    private static let coldStartTraceArmingSecondsEnvironmentKey = "OPENCAST_COLD_START_TRACE_ARMING_SECONDS"
    private static let longShowNotesColdStartProbeEnvironmentKey = "OPENCAST_RUN_LONG_SHOW_NOTES_COLD_START_UI_TESTS"
    private static let longShowNotesColdStartProbeFilePath = "/tmp/opencast-run-long-show-notes-cold-start-ui-tests"
    private static let remotePeelTraceArmingSecondsEnvironmentKey = "OPENCAST_REMOTE_PEEL_TRACE_ARMING_SECONDS"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryTabsAreAvailableOnCompactWidth() throws {
        let app = makeCompletedOnboardingApp()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Inbox"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
    }

    @MainActor
    func testFirstLaunchOnboardingScreenshotsOPMLSkipAndPopularSuggestions() throws {
        let app = makeOnboardingApp(forcesDarkMode: true)
        app.launch()

        assertExists(app.staticTexts["Welcome to OpenCast"], named: "onboarding welcome")
        assertExists(app.staticTexts["No third-party analytics"], named: "no third-party analytics pitch")
        assertExists(elementContaining(label: "Open source", in: app), named: "open source pitch link")
        assertExists(app.staticTexts["Tiny install"], named: "tiny install pitch")
        attachSmokeScreenshot(named: "onboarding_welcome_dark")

        app.buttons["Continue"].tap()
        assertExists(app.buttons["Import OPML"], named: "Import OPML button")
        assertExists(app.buttons["Skip"], named: "Skip OPML onboarding action")
        app.buttons["Apple Podcasts Export Shortcut"].tap()
        assertExists(
            app.staticTexts["This iCloud Shortcut helps export your Apple Podcasts subscriptions into an OPML file that OpenCast can import."],
            named: "Apple Podcasts Shortcut explainer"
        )
        assertExists(app.buttons["Open Shortcut"], named: "Open Shortcut link")
        attachSmokeScreenshot(named: "onboarding_opml_import_dark")

        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Popular Podcasts"], named: "Popular Podcasts onboarding screen")
        assertExists(app.staticTexts["Deterministic Popular Show"], named: "deterministic popular podcast")
        assertExists(app.buttons["Subscribe"].firstMatch, named: "popular podcast Subscribe button")
        assertExists(app.staticTexts["Directory Only Suggestion"], named: "disabled popular podcast suggestion")
        attachSmokeScreenshot(named: "onboarding_popular_podcasts_dark")

        app.buttons["Done"].tap()
        assertExists(app.tabBars.buttons["Library"], named: "Library after onboarding")
        assertDoesNotExist(app.staticTexts["Welcome to OpenCast"], named: "onboarding after Done")
    }

    @MainActor
    func testSettingsDebugRunOnboardingScreenshotsAndKeepsSubscriptions() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            usesStubPopularPodcasts: true
        )
        app.launch()

        openSettings(in: app)
        let diagnosticsButton = app.buttons["Diagnostics"]
        scrollUntilHittable(diagnosticsButton, in: app)
        let runOnboardingButton = app.buttons["Run Onboarding"]
        scrollUntilHittable(runOnboardingButton, in: app)
        XCTAssertGreaterThan(runOnboardingButton.frame.minY, diagnosticsButton.frame.minY)
        attachSmokeScreenshot(named: "settings_debug_run_onboarding")

        runOnboardingButton.tap()
        assertExists(app.staticTexts["Welcome to OpenCast"], named: "debug onboarding welcome")
        attachSmokeScreenshot(named: "settings_debug_onboarding_welcome_light")

        app.buttons["Continue"].tap()
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Deterministic Popular Show"], named: "debug popular suggestions")
        attachSmokeScreenshot(named: "settings_debug_onboarding_popular_light")
        app.buttons["Done"].tap()

        openLibrary(in: app)
        assertExists(seededSubscriptionRow(in: app), named: "seeded subscription after debug onboarding")
    }

    @MainActor
    func testSeededInboxEpisodeCanOpenPlayer() throws {
        let app = makeSeededApp()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Inbox"].waitForExistence(timeout: 5))
        let inboxEpisode = seededEpisodeRow(in: app)
        XCTAssertTrue(inboxEpisode.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Deterministic UI Episode"].exists)
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        XCTAssertTrue(playbackProgress(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists || app.buttons["Play"].exists)

        dismissNowPlayingOverlay(in: app)
        XCTAssertTrue(app.buttons["Play Episode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Summary"].exists)
    }

    @MainActor
    func testSeededBadAudioURLShowsPlaybackFailedAlert() throws {
        let app = makeSeededApp(seedsBadAudioURL: true)
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        let alert = app.alerts["Playback Failed"]
        assertExists(alert, named: "Playback Failed alert", timeout: 10)
        XCTAssertTrue(alert.staticTexts.element(boundBy: 1).exists)
        alert.buttons["OK"].tap()
        assertExists(app.buttons["Play Episode"], named: "Play Episode button after failed autoplay")
    }

    @MainActor
    func testSeededInboxEpisodeAutoplaysAndExpandsNowPlaying() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        attachSmokeScreenshot(named: "inbox_episode_row_wide_artwork")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        attachSmokeScreenshot(named: "episode_tap_expanded_now_playing")

        dismissNowPlayingOverlay(in: app)
        assertExists(app.buttons["Play Episode"], named: "episode detail behind Now Playing")
    }

    @MainActor
    func testSeededMiniPlayerSwitchTabsAndExpands() throws {
        let app = makeSeededApp(forcesDarkMode: false, forcesLightMode: true)
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)

        let miniPlayer = app.buttons["Open Now Playing"]
        assertExists(miniPlayer, named: "mini-player after opening episode")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        app.tabBars.buttons["Inbox"].tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))

        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
    }

    @MainActor
    func testOptInSeededLongShowNotesColdStartInboxEpisodeAutoplaysAndExpandsNowPlaying() throws {
        try requireLongShowNotesColdStartProbe()
        let app = makeSeededApp(seedsLongShowNotes: true, extraFeedCount: 8)
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        waitForExternalTraceIfRequested(environmentKey: Self.coldStartTraceArmingSecondsEnvironmentKey)
        let tapStartedAt = Date.now
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        let tapToNowPlaying = Date.now.timeIntervalSince(tapStartedAt)
        XCTContext.runActivity(
            named: String(format: "Long show notes tap to Now Playing %.3fs", tapToNowPlaying)
        ) { _ in }
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
    }

    @MainActor
    func testSeededEpisodeOpenWhileListeningKeepsNowPlayingCollapsed() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)
        tapBackButton(in: app)

        assertExists(inboxEpisode, named: "seeded inbox episode after returning to Inbox")
        inboxEpisode.tap()

        assertExists(app.buttons["Play Episode"], named: "episode detail while playback continues")
        XCTAssertFalse(nowPlayingOverlay(in: app).exists)
        assertExists(app.buttons["Open Now Playing"], named: "mini-player remains collapsed")
        attachSmokeScreenshot(named: "episode_detail_while_listening")
    }

    @MainActor
    func testSeededPlayEpisodeButtonWhileListeningExpandsNowPlaying() throws {
        let app = makeSeededApp(seedsEpisodeProgress: true)
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        let miniPlayer = app.buttons["Open Now Playing"]
        assertExists(miniPlayer, named: "restored mini-player")
        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)

        let playButton = nowPlayingOverlay(in: app).buttons["Play"].firstMatch
        assertExists(playButton, named: "restored playback play button")
        playButton.tap()
        dismissNowPlayingOverlay(in: app)

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        let completedEpisode = seededCompletedEpisodeRow(in: app)
        assertExists(completedEpisode, named: "completed podcast episode row")
        completedEpisode.tap()

        let playEpisodeButton = app.buttons["Play Episode"]
        assertExists(playEpisodeButton, named: "Play Episode button while another episode is playing")
        waitForExternalTraceIfRequested(environmentKey: Self.playEpisodeTraceArmingSecondsEnvironmentKey)
        playEpisodeButton.tap()

        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control after Play Episode")
    }

    @MainActor
    func testNowPlayingFramePacing() throws {
        let app = makeSeededApp(seedsEpisodeProgress: true)
        // Enable the probe via a launch argument: xctestrun EnvironmentVariables
        // do not reach the cloned UI-test runner's ProcessInfo, but launch
        // arguments set here always reach the app under test.
        app.launchArguments.append("--opencast-frame-probe")
        app.launch()

        // Session 1: expand Now Playing from the restored mini-player.
        let miniPlayer = app.buttons["Open Now Playing"]
        assertExists(miniPlayer, named: "restored mini-player")
        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
        let playButton = nowPlayingOverlay(in: app).buttons["Play"].firstMatch
        assertExists(playButton, named: "restored playback play button")
        playButton.tap()
        dismissNowPlayingOverlay(in: app)

        // Session 2: blue Play Episode button while another episode is playing.
        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()
        let completedEpisode = seededCompletedEpisodeRow(in: app)
        assertExists(completedEpisode, named: "completed podcast episode row")
        completedEpisode.tap()
        let playEpisodeButton = app.buttons["Play Episode"]
        assertExists(playEpisodeButton, named: "Play Episode button while another episode is playing")
        playEpisodeButton.tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control after Play Episode")

        let summary = captureFramePacingSummary(in: app, expectedSessions: 2)
        XCTAssertTrue(summary.contains("session="), "expected frame pacing summary, got: \(summary)")
    }

    @MainActor
    func testSeededEpisodeProgressRestoresMiniPlayerAndShowsRows() throws {
        let app = makeSeededApp(seedsEpisodeProgress: true)
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        assertExists(app.buttons["Open Now Playing"], named: "restored mini-player")

        app.tabBars.buttons["Inbox"].tap()
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded in-progress inbox episode")
        assertExists(app.staticTexts["2m left"], named: "remaining time row label")
        attachSmokeScreenshot(named: "inbox_episode_progress")

        app.tabBars.buttons["Library"].tap()
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        let completedEpisode = seededCompletedEpisodeRow(in: app)
        assertExists(completedEpisode, named: "completed podcast episode row")
        XCTAssertTrue((completedEpisode.value as? String)?.contains("Completed") == true)
        attachSmokeScreenshot(named: "podcast_detail_episode_progress")

        app.buttons["Open Now Playing"].tap()
        assertNowPlayingOverlay(in: app)
        assertExists(nowPlayingOverlay(in: app).buttons["Play"].firstMatch, named: "restored paused playback control")
    }

    @MainActor
    func testSeededLibraryPodcastCanSwipeRemove() throws {
        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let podcastRow = seededSubscriptionRow(in: app)
        assertExists(podcastRow, named: "seeded library podcast row")

        podcastRow.swipeLeft()
        let removeButton = app.buttons["Remove"]
        assertExists(removeButton, named: "Remove swipe action")
        attachSmokeScreenshot(named: "library_swipe_remove")
        removeButton.tap()

        let confirmButton = app.buttons["Remove Podcast"]
        assertExists(confirmButton, named: "Remove Podcast confirmation action")
        attachSmokeScreenshot(named: "library_remove_confirmation")
        confirmButton.tap()

        XCTAssertTrue(podcastRow.waitForNonExistence(timeout: 5))
        assertExists(app.staticTexts["No Subscriptions"], named: "empty library after removal")
        attachSmokeScreenshot(named: "library_after_swipe_remove")
    }

    @MainActor
    func testSeededCompactLibraryEpisodeBackReturnsToPodcast() throws {
        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        assertExists(app.staticTexts["Episodes"], named: "podcast detail episodes section")
        let podcastEpisode = seededEpisodeRow(in: app)
        assertExists(podcastEpisode, named: "podcast detail seeded episode")
        podcastEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)
        assertExists(app.buttons["Play Episode"], named: "Play Episode button")
        assertExists(app.buttons["Open Now Playing"], named: "autoplay mini-player after opening library episode")
        attachSmokeScreenshot(named: "compact_library_episode_detail")

        tapBackToPodcastButton(in: app)
        assertExists(app.staticTexts["Episodes"], named: "podcast detail after returning from episode")
        assertExists(seededEpisodeRow(in: app), named: "podcast episode row after returning from episode")
        attachSmokeScreenshot(named: "compact_podcast_detail_after_episode_back")
    }

    @MainActor
    func testSeededSplitLibraryEpisodeBackReturnsToPodcast() throws {
        let app = makeSeededApp()
        app.launch()

        if app.tabBars.buttons["Library"].waitForExistence(timeout: 3) {
            throw XCTSkip("Split navigation requires a regular-width destination.")
        }

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded split library podcast")
        libraryPodcast.tap()

        assertExists(app.staticTexts["Episodes"], named: "split podcast detail episodes section")
        let podcastEpisode = seededEpisodeRow(in: app)
        assertExists(podcastEpisode, named: "split podcast detail seeded episode")
        podcastEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)
        assertExists(app.buttons["Play Episode"], named: "split Play Episode button")
        assertExists(app.buttons["Open Now Playing"], named: "split autoplay mini-player after opening library episode")
        attachSmokeScreenshot(named: "split_library_episode_detail")

        tapBackToPodcastButton(in: app)
        assertExists(app.staticTexts["Episodes"], named: "split podcast detail after returning from episode")
        assertExists(seededEpisodeRow(in: app), named: "split podcast episode row after returning from episode")
        attachSmokeScreenshot(named: "split_podcast_detail_after_episode_back")
    }

    @MainActor
    func testSeededNowPlayingProgressCanScrub() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control")

        let initialValue = progress.value as? String
        let start = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        let end = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5))
        start.press(forDuration: 0.08, thenDragTo: end)

        let scrubbed = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String else {
                return false
            }

            return value != initialValue && !value.hasPrefix("0:00 elapsed")
        }
        let expectation = XCTNSPredicateExpectation(predicate: scrubbed, object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed)
        attachSmokeScreenshot(named: "now_playing_scrubbed")
    }

    @MainActor
    func testSeededNowPlayingCanDismissFromContentArea() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dragDismissNowPlayingOverlayFromArtwork(in: app)
        XCTAssertTrue(nowPlayingOverlay(in: app).waitForNonExistence(timeout: 5))
        assertExists(app.buttons["Open Now Playing"], named: "mini-player after content-area dismiss")
    }

    @MainActor
    func testSeededNowPlayingArtworkPeelsOpenSoundLabPanel() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        waitForExternalTraceIfRequested(environmentKey: Self.seededPeelTraceArmingSecondsEnvironmentKey)
        peelNowPlayingArtwork(in: app)
        attachPeelScreenshotIfRequested(in: app, name: "Now Playing artwork peel open")

        assertNowPlayingOverlay(in: app)
        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")
        assertExists(app.buttons["Voice Boost"], named: "Voice Boost peel toggle")
        XCTAssertFalse(app.buttons["Smart Speed"].exists)
        XCTAssertFalse(app.buttons["Skip Intros"].exists)
        XCTAssertFalse(app.buttons["Show Alerts"].exists)
    }

    @MainActor
    func testSeededNowPlayingArtworkPeelClosesSoundLabPanel() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        peelNowPlayingArtwork(in: app)
        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")

        closeNowPlayingArtworkPeel(in: app)
        attachPeelScreenshotIfRequested(in: app, name: "Now Playing artwork peel closed")

        assertNowPlayingOverlay(in: app)
        XCTAssertTrue(nowPlayingPeelSettingsPanel(in: app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Voice Boost"].exists)
    }

    @MainActor
    func testSeededNowPlayingArtworkTapClosesSoundLabPanel() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        peelNowPlayingArtwork(in: app)
        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")

        nowPlayingArtwork(in: app).tap()

        assertNowPlayingOverlay(in: app)
        XCTAssertTrue(nowPlayingPeelSettingsPanel(in: app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Voice Boost"].exists)
    }

    @MainActor
    func testSeededNowPlayingArtworkTapOpensSoundLabPanel() throws {
        let app = makeSeededApp()
        app.launch()

        openSeededNowPlaying(in: app)
        waitForExternalTraceIfRequested(environmentKey: Self.seededPeelTraceArmingSecondsEnvironmentKey)
        nowPlayingArtwork(in: app).tap()

        assertNowPlayingOverlay(in: app)
        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")
        assertExists(app.buttons["Voice Boost"], named: "Voice Boost peel toggle")
    }

    @MainActor
    func testSeededNowPlayingArtworkPeelDragDoesNotDismissOrMoveCard() throws {
        let app = makeSeededApp()
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        let initialFrame = overlay.frame

        peelNowPlayingArtwork(in: app)

        assertNowPlayingOverlay(in: app)
        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")
        XCTAssertEqual(overlay.frame.minY, initialFrame.minY, accuracy: 6)
        XCTAssertEqual(overlay.frame.height, initialFrame.height, accuracy: 6)
    }

    @MainActor
    func testSeededNowPlayingColorCheckerArtworkPeelScreenshots() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            artworkVariant: "color-checker"
        )
        app.launch()

        openSeededNowPlaying(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        attachSmokeScreenshot(named: "color_checker_now_playing_closed")

        peelNowPlayingArtwork(in: app)

        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")
        attachSmokeScreenshot(named: "color_checker_now_playing_peel_open")
    }

    @MainActor
    func testSeededNowPlayingPlaceholderArtworkPeelScreenshots() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            artworkVariant: "placeholder"
        )
        app.launch()

        openSeededNowPlaying(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        attachSmokeScreenshot(named: "placeholder_now_playing_closed")

        peelNowPlayingArtwork(in: app)

        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")
        attachSmokeScreenshot(named: "placeholder_now_playing_peel_open")
    }

    @MainActor
    func testSeededCompactSmokeScreenshots() throws {
        let app = makeSeededApp()
        app.launch()

        let libraryTab = app.tabBars.buttons["Library"]
        assertExists(libraryTab, named: "Library tab")
        libraryTab.tap()
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")

        libraryPodcast.tap()
        assertExists(app.staticTexts["Episodes"], named: "podcast detail episodes section")
        assertExists(seededEpisodeRow(in: app), named: "podcast detail seeded episode")
        attachSmokeScreenshot(named: "podcast_detail")

        tapBackButton(in: app)
        assertExists(libraryPodcast, named: "Library root after podcast detail")

        app.tabBars.buttons["Inbox"].tap()
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)
        let playEpisodeButton = app.buttons["Play Episode"]
        assertExists(playEpisodeButton, named: "Play Episode button")
        assertExists(app.staticTexts["Summary"], named: "episode summary heading")
        attachSmokeScreenshot(named: "episode_detail")

        app.buttons["Open Now Playing"].tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5) || app.buttons["Play"].exists)
        assertPlayerUtilityControlsExist(in: app)

        dismissNowPlayingOverlay(in: app)
        tapBackButton(in: app)
        assertExists(inboxEpisode, named: "Inbox root after playback")
        assertMiniPlayerDoesNotCover(inboxEpisode, named: "seeded inbox episode", in: app)
        attachSmokeScreenshot(named: "inbox_compact")

        libraryTab.tap()
        assertExists(libraryPodcast, named: "seeded library podcast with mini-player")
        assertMiniPlayerDoesNotCover(libraryPodcast, named: "seeded library podcast", in: app)
        attachSmokeScreenshot(named: "library_compact")

        app.buttons["Open Now Playing"].tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        assertPlayerUtilityControlsExist(in: app)
        attachSmokeScreenshot(named: "now_playing_expanded")

        dismissNowPlayingOverlay(in: app)
        assertExists(libraryPodcast, named: "Library after dismissing Now Playing")
        assertMiniPlayerDoesNotCover(libraryPodcast, named: "seeded library podcast after dismiss", in: app)
        attachSmokeScreenshot(named: "library_compact_after_dismiss")

        app.tabBars.buttons["Settings"].tap()
        let episodeProgressRow = app.staticTexts["Episode Progress"]
        scrollUntilExists(episodeProgressRow, in: app)
        assertExists(app.staticTexts["iCloud Sync"], named: "iCloud Sync section")
        assertExists(app.staticTexts["Status"], named: "iCloud sync status row")
        assertExists(app.staticTexts["Subscriptions"], named: "Subscriptions row")
        assertExists(episodeProgressRow, named: "Episode Progress row")
        let downloadedEpisodesRow = app.staticTexts["Downloaded Episodes"]
        scrollUntilExists(downloadedEpisodesRow, in: app)
        assertExists(app.staticTexts["Local Storage"], named: "Local Storage section")
        assertExists(app.staticTexts["Feed Cache"], named: "Feed Cache row")
        assertExists(downloadedEpisodesRow, named: "Downloaded Episodes row")
        attachSmokeScreenshot(named: "settings_sync")

        let diagnosticsLink = app.buttons["Diagnostics"]
        scrollUntilHittable(diagnosticsLink, in: app)
        assertMiniPlayerDoesNotCover(diagnosticsLink, named: "Diagnostics row", in: app)
        diagnosticsLink.tap()

        let repairButton = app.buttons["Repair Sync Duplicates"]
        scrollUntilHittable(repairButton, in: app)
        scrollUntilMiniPlayerDoesNotCover(repairButton, in: app)
        assertMiniPlayerDoesNotCover(repairButton, named: "Repair Sync Duplicates button", in: app)
        repairButton.tap()
        assertExists(app.staticTexts["Last Repair, No Issues"], named: "No Issues repair result")
        assertExists(app.staticTexts["Duplicate Rows"], named: "Duplicate Rows repair result")
        attachSmokeScreenshot(named: "settings_sync_repair")
    }

    @MainActor
    func testSeededCompletedDownloadSmokeScreenshots() throws {
        let app = makeSeededApp(seedsCompletedDownload: true)
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)
        assertExists(app.buttons["Play Episode"], named: "Play Episode button")
        assertExists(app.buttons["Play Downloaded"], named: "Play Downloaded button")
        assertExists(app.buttons["Delete Download"], named: "Delete Download button")
        attachSmokeScreenshot(named: "episode_detail_completed_download")

        app.tabBars.buttons["Settings"].tap()
        let deleteAllDownloadsButton = app.buttons["Delete All Downloads"]
        scrollUntilHittable(deleteAllDownloadsButton, in: app)
        assertExists(app.staticTexts["Downloaded Episodes"], named: "Downloaded Episodes row")
        assertExists(deleteAllDownloadsButton, named: "Delete All Downloads button")
        attachSmokeScreenshot(named: "settings_downloads")
    }

    @MainActor
    func testSettingsClearAutomaticCachesAndDeleteDownloadsStaySeparate() throws {
        let app = makeSeededApp(seedsCompletedDownload: true)
        app.launch()

        openSettings(in: app)

        let deleteAllDownloadsButton = app.buttons["Delete All Downloads"]
        scrollUntilHittable(deleteAllDownloadsButton, in: app)
        assertExists(app.staticTexts["Feed Cache"], named: "Feed Cache row before cache clear")
        assertExists(app.staticTexts["Artwork Cache"], named: "Artwork Cache row before cache clear")
        assertExists(deleteAllDownloadsButton, named: "Delete All Downloads before cache clear")

        let clearCachesButton = app.buttons["Clear Automatic Caches"].firstMatch
        scrollUntilHittable(clearCachesButton, in: app)
        clearCachesButton.tap()
        app.buttons["Clear Automatic Caches"].firstMatch.tap()

        assertExists(deleteAllDownloadsButton, named: "Delete All Downloads after cache clear")

        deleteAllDownloadsButton.tap()
        app.buttons["Delete Downloads"].tap()

        assertDoesNotExist(deleteAllDownloadsButton, named: "Delete All Downloads after deleting downloads", timeout: 5)
        assertExists(app.staticTexts["Feed Cache"], named: "Feed Cache row after deleting downloads")
        assertExists(app.staticTexts["Artwork Cache"], named: "Artwork Cache row after deleting downloads")
    }

    @MainActor
    func testEpisodeActionsMarkPlayedAndClearProgress() throws {
        let progressApp = makeSeededApp(seedsEpisodeProgress: true)
        progressApp.launch()
        openSeededEpisodeDetail(in: progressApp)

        progressApp.buttons["Episode Actions"].tap()
        progressApp.buttons["Clear Progress"].tap()
        let clearProgressConfirmation = progressApp.sheets.buttons["Clear Progress"].firstMatch
        assertExists(clearProgressConfirmation, named: "Clear Progress confirmation")
        clearProgressConfirmation.tap()
        assertDoesNotExist(progressApp.staticTexts["2m left"], named: "remaining time after Clear Progress", timeout: 5)
        assertExists(progressApp.buttons["Play Episode"], named: "Play Episode after Clear Progress")

        let markPlayedApp = makeSeededApp()
        markPlayedApp.launch()
        openSeededEpisodeDetail(in: markPlayedApp)

        markPlayedApp.buttons["Episode Actions"].tap()
        let markPlayedButton = markPlayedApp.buttons["Mark Played"]
        assertExists(markPlayedButton, named: "Mark Played action")
        markPlayedButton.tap()
        assertExists(
            elementContaining(label: "Completed", in: markPlayedApp),
            named: "Completed status after Mark Played",
            timeout: 10
        )
    }

    @MainActor
    func testNowPlayingVoiceBoostCanToggleWithScreenshots() throws {
        let app = makeSeededApp(seedsPerEpisodeVoiceBoost: true)
        app.launch()

        openSeededNowPlayingSoundLab(in: app)

        let voiceBoostToggle = app.buttons["Voice Boost"]
        assertExists(voiceBoostToggle, named: "Voice Boost peel toggle")
        assertToggle(voiceBoostToggle, isOn: true)
        attachSmokeScreenshot(named: "now_playing_voice_boost_on")

        tapToggle(voiceBoostToggle, to: false)
        attachSmokeScreenshot(named: "now_playing_voice_boost_off")

        tapToggle(voiceBoostToggle, to: true)
    }

    @MainActor
    func testNowPlayingVoiceBoostSupportsLargeDynamicType() throws {
        let app = makeSeededApp(
            seedsPerEpisodeVoiceBoost: true,
            preferredContentSizeCategoryName: "UICTContentSizeCategoryAccessibilityL"
        )
        app.launch()

        openSeededNowPlayingSoundLab(in: app)

        let voiceBoostToggle = app.buttons["Voice Boost"]
        assertToggle(voiceBoostToggle, isOn: true)
        attachSmokeScreenshot(named: "now_playing_voice_boost_dynamic_type")

        tapToggle(voiceBoostToggle, to: false)
        tapToggle(voiceBoostToggle, to: true)
    }

    @MainActor
    func testVoiceBoostDiagnosticsSectionCanBeShownForManualDeviceRuns() throws {
        #if !DEBUG
        throw XCTSkip("Voice Boost diagnostics section is Debug-only.")
        #else
        let app = makeSeededApp()
        app.launchArguments.append("--opencast-capture-voiceboost-diagnostics")
        app.launchEnvironment["OPENCAST_CAPTURE_VOICEBOOST_DIAGNOSTICS"] = "1"
        app.launch()

        openSettings(in: app)

        let runDeviceProbeButton = app.buttons["Run Device Probe"]
        scrollUntilHittable(runDeviceProbeButton, in: app)
        assertExists(runDeviceProbeButton, named: "Run Device Probe button")
        assertExists(app.staticTexts["Last Device Probe"], named: "Last Device Probe diagnostics row")
        assertExists(
            diagnosticsRow(in: app, title: "Last Device Probe", value: "Not Run"),
            named: "initial Last Device Probe value"
        )
        assertExists(app.staticTexts["Device Probe Report"], named: "Device Probe Report diagnostics row")
        assertExists(
            diagnosticsRow(in: app, title: "Device Probe Report", value: "Not Written"),
            named: "initial Device Probe Report value"
        )
        assertExists(app.staticTexts["Device Probe App State"], named: "Device Probe App State diagnostics row")

        let processedFramesRow = app.staticTexts["Processed Frames"]
        scrollUntilExists(processedFramesRow, in: app)
        let processCallbacksRow = app.staticTexts["Process Callbacks"]
        scrollUntilExists(processCallbacksRow, in: app)
        assertExists(processCallbacksRow, named: "Process Callbacks diagnostics row")
        let maxCallbackRow = app.staticTexts["Max Callback ns"]
        scrollUntilExists(maxCallbackRow, in: app)
        assertExists(maxCallbackRow, named: "Max Callback diagnostics row")
        let playbackStateRow = app.staticTexts["Playback State"]
        scrollUntilExists(playbackStateRow, in: app)
        attachSmokeScreenshot(named: "settings_voice_boost_diagnostics")
        #endif
    }

    @MainActor
    func testOptInVoiceBoostSettingsDeviceProbeCanRunFromForeground() throws {
        #if !DEBUG
        throw XCTSkip("Voice Boost diagnostics section is Debug-only.")
        #else
        #if !OPENCAST_RUN_SETTINGS_VOICEBOOST_PROBE_UI_TESTS
        let shouldRunSettingsProbe = ProcessInfo.processInfo.environment["OPENCAST_RUN_SETTINGS_VOICEBOOST_PROBE_UI_TESTS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/opencast-run-settings-voiceboost-probe-ui-tests")
        guard shouldRunSettingsProbe else {
            throw XCTSkip("Set OPENCAST_RUN_SETTINGS_VOICEBOOST_PROBE_UI_TESTS=1 or create /tmp/opencast-run-settings-voiceboost-probe-ui-tests to run the live Settings Voice Boost device-probe UI test.")
        }
        #endif

        let app = makeSeededApp()
        app.launchArguments.append("--opencast-capture-voiceboost-diagnostics")
        app.launchEnvironment["OPENCAST_CAPTURE_VOICEBOOST_DIAGNOSTICS"] = "1"
        app.launch()

        openSettings(in: app)

        let runDeviceProbeButton = app.buttons["Run Device Probe"]
        scrollUntilHittable(runDeviceProbeButton, in: app)
        assertExists(runDeviceProbeButton, named: "Run Device Probe button")
        runDeviceProbeButton.tap()

        assertExists(app.staticTexts["Running Device Probe"], named: "Running Device Probe progress", timeout: 5)
        let passedResult = diagnosticsRow(in: app, title: "Last Device Probe", value: "settings: passed")
        if !passedResult.waitForExistence(timeout: 90) {
            let timedOutExists = diagnosticsRow(in: app, title: "Last Device Probe", value: "settings: timedOut").exists
            let failedExists = diagnosticsRow(in: app, title: "Last Device Probe", value: "settings: failed").exists
            XCTFail("Expected Settings Voice Boost device probe to pass; timedOut=\(timedOutExists), failed=\(failedExists)")
        }
        assertExists(
            diagnosticsRow(in: app, title: "Device Probe Report", value: "Report Written"),
            named: "written Device Probe report status"
        )
        assertExists(app.staticTexts["Device Probe App State"], named: "Device Probe App State diagnostics row")
        attachSmokeScreenshot(named: "settings_voice_boost_device_probe_passed")
        #endif
    }

    @MainActor
    func testOptInDebuggerAlmanacRemoteFeedCanPlayFromAppUI() throws {
        let shouldRunRemoteProbe = ProcessInfo.processInfo.environment["OPENCAST_RUN_REMOTE_VOICEBOOST_UI_TESTS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/opencast-run-remote-voiceboost-ui-tests")
        guard shouldRunRemoteProbe else {
            throw XCTSkip("Set OPENCAST_RUN_REMOTE_VOICEBOOST_UI_TESTS=1 or create /tmp/opencast-run-remote-voiceboost-ui-tests to run the live Debugger's Almanac UI playback probe.")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-dark-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = "https://debuggersalmanac.mindovermatterismagic.com/feed.xml"
        app.launchEnvironment["OPENCAST_CAPTURE_VOICEBOOST_DIAGNOSTICS"] = "1"
        app.launch()

        openLibrary(in: app)
        tapAddPodcastButton(in: app)
        app.buttons["Subscribe"].tap()

        assertExists(app.staticTexts["The Debugger's Almanac"], named: "Debugger's Almanac subscription", timeout: 30)
        openInbox(in: app)

        let firstEpisode = debuggerAlmanacFirstEpisode(in: app)
        assertExists(firstEpisode, named: "Debugger's Almanac inbox episode", timeout: 30)
        firstEpisode.tap()

        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control", timeout: 20)
        var processedFrames = waitForVoiceBoostProcessedFrames(in: app, minProcessedFrames: 1, timeout: 40)

        let pauseButton = nowPlayingOverlay(in: app).buttons["Pause"].firstMatch
        assertExists(pauseButton, named: "Pause button", timeout: 20)
        pauseButton.tap()
        let playButton = nowPlayingOverlay(in: app).buttons["Play"].firstMatch
        assertExists(playButton, named: "Play button after pausing", timeout: 10)
        playButton.tap()
        processedFrames = waitForVoiceBoostProcessedFrames(
            in: app,
            minProcessedFrames: processedFrames + 1,
            timeout: 30
        )

        app.buttons["Skip Forward 30 Seconds"].tap()
        processedFrames = waitForVoiceBoostProcessedFrames(
            in: app,
            minProcessedFrames: processedFrames + 1,
            timeout: 30
        )

        app.buttons["Skip Back 15 Seconds"].tap()
        processedFrames = waitForVoiceBoostProcessedFrames(
            in: app,
            minProcessedFrames: processedFrames + 1,
            timeout: 30
        )

        let progress = playbackProgress(in: app)
        let scrubStart = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
        let scrubEnd = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.5))
        scrubStart.press(forDuration: 0.08, thenDragTo: scrubEnd)
        processedFrames = waitForVoiceBoostProcessedFrames(
            in: app,
            minProcessedFrames: processedFrames + 1,
            timeout: 40
        )

        let playbackSpeedButton = app.buttons["Playback Speed"]
        assertExists(playbackSpeedButton, named: "Playback Speed control")
        playbackSpeedButton.tap()
        let fasterSpeedButton = app.buttons["1.25x"]
        assertExists(fasterSpeedButton, named: "1.25x speed option")
        fasterSpeedButton.tap()
        processedFrames = waitForVoiceBoostProcessedFrames(
            in: app,
            minProcessedFrames: processedFrames + 1,
            timeout: 30
        )

        let sleepTimerButton = app.buttons["Sleep Timer"]
        assertExists(sleepTimerButton, named: "Sleep Timer control")
        sleepTimerButton.tap()
        let fifteenMinuteSleepButton = app.buttons["15 Minutes"]
        assertExists(fifteenMinuteSleepButton, named: "15 Minutes sleep timer option")
        fifteenMinuteSleepButton.tap()
        assertElementValueNotEqual(sleepTimerButton, "Off", named: "armed Sleep Timer control")
        processedFrames = waitForVoiceBoostProcessedFrames(
            in: app,
            minProcessedFrames: processedFrames + 1,
            timeout: 30
        )

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date.now.addingTimeInterval(2))
        app.activate()
        if !nowPlayingOverlay(in: app).waitForExistence(timeout: 5) {
            let miniPlayer = app.buttons["Open Now Playing"]
            assertExists(miniPlayer, named: "mini-player after foregrounding", timeout: 10)
            miniPlayer.tap()
        }
        assertNowPlayingOverlay(in: app)
        _ = waitForVoiceBoostProcessedFrames(
            in: app,
            minProcessedFrames: processedFrames + 1,
            timeout: 40
        )

        attachSmokeScreenshot(named: "american_prestige_remote_playback")
    }

    @MainActor
    func testOptInDebuggerAlmanacNowPlayingArtworkPeelScreenshot() throws {
        let shouldRunRemotePeelProbe = ProcessInfo.processInfo.environment["OPENCAST_RUN_REMOTE_PEEL_UI_TESTS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/opencast-run-remote-peel-ui-tests")
        guard shouldRunRemotePeelProbe else {
            throw XCTSkip("Set OPENCAST_RUN_REMOTE_PEEL_UI_TESTS=1 or create /tmp/opencast-run-remote-peel-ui-tests to run the live Debugger's Almanac peel visual probe.")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-light-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = "https://debuggersalmanac.mindovermatterismagic.com/feed.xml"
        app.launch()

        openLibrary(in: app)
        tapAddPodcastButton(in: app)
        app.buttons["Subscribe"].tap()

        assertExists(app.staticTexts["The Debugger's Almanac"], named: "Debugger's Almanac subscription", timeout: 30)
        openInbox(in: app)

        let firstEpisode = debuggerAlmanacFirstEpisode(in: app)
        assertExists(firstEpisode, named: "Debugger's Almanac inbox episode", timeout: 30)
        waitForExternalTraceIfRequested(environmentKey: Self.remotePeelTraceArmingSecondsEnvironmentKey)
        firstEpisode.tap()

        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control", timeout: 20)
        peelNowPlayingArtwork(in: app)

        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")
        assertExists(app.buttons["Voice Boost"], named: "Voice Boost peel toggle")
        XCTAssertFalse(app.buttons["Smart Speed"].exists)
        XCTAssertFalse(app.buttons["Skip Intros"].exists)
        XCTAssertFalse(app.buttons["Show Alerts"].exists)
        attachSmokeScreenshot(named: "debuggers_almanac_now_playing_peel_open")
    }

    @MainActor
    func testAddPodcastRSSClipboardPrefillScreenshots() throws {
        try verifyAddPodcastRSSClipboardPrefill(
            forcesDarkMode: true,
            forcesLightMode: false,
            screenshotName: "add_podcast_rss_clipboard_dark"
        )
        try verifyAddPodcastRSSClipboardPrefill(
            forcesDarkMode: false,
            forcesLightMode: true,
            screenshotName: "add_podcast_rss_clipboard_light"
        )
    }

    @MainActor
    func testSeededLightNowPlayingScreenshot() throws {
        let app = makeSeededApp(forcesDarkMode: false, forcesLightMode: true)
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        assertPlayerUtilityControlsExist(in: app)
        attachSmokeScreenshot(named: "now_playing_expanded_light")

        let pauseButton = nowPlayingOverlay(in: app).buttons["Pause"].firstMatch
        if pauseButton.waitForExistence(timeout: 5) {
            pauseButton.tap()
        }
        assertExists(nowPlayingOverlay(in: app).buttons["Play"].firstMatch, named: "Play button after pausing")
        attachSmokeScreenshot(named: "now_playing_expanded_light_paused")
    }

    @MainActor
    private func verifyAddPodcastRSSClipboardPrefill(
        forcesDarkMode: Bool,
        forcesLightMode: Bool,
        screenshotName: String
    ) throws {
        let pastedFeedURL = "http://seed.mindovermatterismagic.com/feed.xml"
        let app = makeSeededApp(
            forcesDarkMode: forcesDarkMode,
            forcesLightMode: forcesLightMode
        )
        app.launchEnvironment["OPENCAST_TEST_CLIPBOARD_STRING"] = pastedFeedURL
        app.launch()

        openLibrary(in: app)
        tapAddPodcastButton(in: app)

        assertExists(app.staticTexts["Add Podcast"], named: "Add Podcast title")
        let feedURLField = app.textFields["RSS Feed URL"]
        assertExists(feedURLField, named: "RSS Feed URL text field")
        XCTAssertEqual(feedURLField.value as? String, pastedFeedURL)
        assertExists(app.staticTexts["Paste from Clipboard"], named: "Paste from Clipboard card")
        assertExists(app.buttons["Subscribe"], named: "Subscribe button")
        attachSmokeScreenshot(named: screenshotName)

        app.buttons["Cancel"].tap()
        app.terminate()
    }

    @MainActor
    private func makeSeededApp(
        forcesDarkMode: Bool = true,
        forcesLightMode: Bool = false,
        seedsCompletedDownload: Bool = false,
        seedsBadAudioURL: Bool = false,
        seedsEpisodeProgress: Bool = false,
        seedsPerEpisodeVoiceBoost: Bool = false,
        seedsLongShowNotes: Bool = false,
        extraFeedCount: Int = 0,
        usesStubPopularPodcasts: Bool = false,
        artworkVariant: String? = nil,
        preferredContentSizeCategoryName: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-ui-library"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        if ProcessInfo.processInfo.environment["OPENCAST_FRAME_PROBE"] == "1" {
            app.launchArguments.append("--opencast-frame-probe")
            app.launchEnvironment["OPENCAST_FRAME_PROBE"] = "1"
        }
        if forcesDarkMode {
            app.launchArguments.append("--opencast-force-dark-mode")
            app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        }
        if forcesLightMode {
            app.launchArguments.append("--opencast-force-light-mode")
            app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        }
        if seedsCompletedDownload {
            app.launchArguments.append("--opencast-seed-completed-download")
            app.launchEnvironment["OPENCAST_SEED_COMPLETED_DOWNLOAD"] = "1"
        }
        if seedsEpisodeProgress {
            app.launchArguments.append("--opencast-seed-episode-progress")
            app.launchEnvironment["OPENCAST_SEED_EPISODE_PROGRESS"] = "1"
        }
        if seedsBadAudioURL {
            app.launchEnvironment["OPENCAST_SEED_BAD_AUDIO_URL"] = "1"
        }
        if seedsPerEpisodeVoiceBoost {
            app.launchEnvironment[Self.seedVoiceBoostModeEnvironmentKey] = Self.perEpisodeVoiceBoostModeValue
        }
        if seedsLongShowNotes {
            app.launchEnvironment["OPENCAST_SEED_LONG_SHOW_NOTES"] = "1"
        }
        if extraFeedCount > 0 {
            app.launchEnvironment["OPENCAST_SEED_EXTRA_FEED_COUNT"] = String(extraFeedCount)
        }
        if usesStubPopularPodcasts {
            app.launchArguments.append("--opencast-stub-popular-podcasts")
            app.launchEnvironment["OPENCAST_STUB_POPULAR_PODCASTS"] = "1"
        }
        if let artworkVariant {
            app.launchEnvironment["OPENCAST_UI_TEST_ARTWORK_VARIANT"] = artworkVariant
        }
        if let preferredContentSizeCategoryName {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                preferredContentSizeCategoryName
            ]
        }
        return app
    }

    @MainActor
    private func makeCompletedOnboardingApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--opencast-ui-testing")
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        return app
    }

    @MainActor
    private func makeOnboardingApp(forcesDarkMode: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-onboarding",
            "--opencast-stub-popular-podcasts"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_ONBOARDING"] = "1"
        app.launchEnvironment["OPENCAST_STUB_POPULAR_PODCASTS"] = "1"
        if forcesDarkMode {
            app.launchArguments.append("--opencast-force-dark-mode")
            app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        } else {
            app.launchArguments.append("--opencast-force-light-mode")
            app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        }
        return app
    }

    @MainActor
    private func seededEpisodeRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Self.seededEpisodeRowIdentifier).firstMatch
    }

    @MainActor
    private func seededCompletedEpisodeRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Self.seededCompletedEpisodeRowIdentifier).firstMatch
    }

    @MainActor
    private func seededSubscriptionRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.seededSubscriptionRowIdentifier).firstMatch
    }

    @MainActor
    private func tapBackButton(in app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
    }

    @MainActor
    private func tapBackToPodcastButton(in app: XCUIApplication) {
        let labels = ["UI Test Show", "Podcast", "Back"]
        for label in labels {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 1) {
                button.tap()
                return
            }
        }

        tapBackButton(in: app)
    }

    @MainActor
    private func assertNowPlayingOverlay(in app: XCUIApplication) {
        assertExists(nowPlayingOverlay(in: app), named: "Now Playing overlay")
    }

    @MainActor
    private func assertPlayerUtilityControlsExist(in app: XCUIApplication) {
        assertExists(app.buttons["Playback Speed"], named: "Playback Speed control")
        assertExists(app.buttons["AirPlay"], named: "AirPlay control")
        assertExists(app.buttons["Sleep Timer"], named: "Sleep Timer control")
    }

    @MainActor
    private func openSeededNowPlayingSoundLab(in app: XCUIApplication) {
        openSeededNowPlaying(in: app)
        peelNowPlayingArtwork(in: app)
        assertExists(nowPlayingPeelSettingsPanel(in: app), named: "Now Playing Sound Lab panel")
    }

    @MainActor
    private func openSeededNowPlaying(in app: XCUIApplication) {
        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
    }

    @MainActor
    private func openSeededEpisodeDetail(in app: XCUIApplication) {
        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        if nowPlayingOverlay(in: app).waitForExistence(timeout: 2) {
            dismissNowPlayingOverlay(in: app)
        }

        assertExists(app.buttons["Play Episode"], named: "seeded episode detail")
    }

    @MainActor
    private func dismissNowPlayingOverlay(in app: XCUIApplication) {
        let overlay = nowPlayingOverlay(in: app)
        assertExists(overlay, named: "expanded Now Playing overlay before dismissal")

        dragDismissNowPlayingOverlay(in: app)

        assertExists(app.buttons["Open Now Playing"], named: "mini-player after dismissing Now Playing")
        XCTAssertFalse(overlay.isHittable)
    }

    @MainActor
    private func dragDismissNowPlayingOverlay(in app: XCUIApplication) {
        dragDismissNowPlayingOverlay(in: app, startY: 0.24)
    }

    @MainActor
    private func dragDismissNowPlayingOverlay(in app: XCUIApplication, startY: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func dragDismissNowPlayingOverlayFromArtwork(in app: XCUIApplication) {
        let artwork = nowPlayingArtwork(in: app)
        assertExists(artwork, named: "Now Playing artwork before dismissal")
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.42))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.74))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func peelNowPlayingArtwork(in app: XCUIApplication) {
        let artwork = nowPlayingArtwork(in: app)
        assertExists(artwork, named: "Now Playing artwork before peel")
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.52))
        let end = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.48))
        start.press(forDuration: 0.10, thenDragTo: end)
    }

    @MainActor
    private func closeNowPlayingArtworkPeel(in app: XCUIApplication) {
        let artwork = nowPlayingArtwork(in: app)
        assertExists(artwork, named: "Now Playing artwork before peel close")
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.52))
        let end = start.withOffset(CGVector(dx: max(180, artwork.frame.width * 2.2), dy: 0))
        start.press(forDuration: 0.06, thenDragTo: end)
    }

    @MainActor
    private func attachPeelScreenshotIfRequested(in app: XCUIApplication, name: String) {
        let shouldAttach = ProcessInfo.processInfo.environment["OPENCAST_ATTACH_PEEL_SCREENSHOTS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/opencast-attach-peel-screenshots")
        guard shouldAttach else {
            return
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func nowPlayingOverlay(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Now Playing"]
    }

    @MainActor
    private func nowPlayingArtwork(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Now Playing Artwork"]
    }

    @MainActor
    private func nowPlayingPeelSettingsPanel(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Now Playing Sound Lab"]
    }

    @MainActor
    private func playbackProgress(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Playback Progress"]
    }

    /// Reads the frame-pacing probe summaries the app publishes through the
    /// accessibility tree and saves them as an .xcresult attachment, since the
    /// probe's on-disk logs live on an unreadable simulator clone and the
    /// runner's stdout is not streamed to the host.
    @MainActor
    @discardableResult
    private func captureFramePacingSummary(
        in app: XCUIApplication,
        expectedSessions: Int,
        timeout: TimeInterval = 15
    ) -> String {
        let element = app.descendants(matching: .any)["Frame Pacing Summary"]
        let deadline = Date().addingTimeInterval(timeout)
        var value = ""
        while Date() < deadline {
            value = (element.value as? String) ?? ""
            let sessions = value.components(separatedBy: "session=").count - 1
            if sessions >= expectedSessions {
                break
            }
            usleep(250_000)
        }

        let attachment = XCTAttachment(string: value)
        attachment.name = "FramePacingSummary"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("FRAMEPACING_SUMMARY: \(value)")
        return value
    }

    @MainActor
    private func openLibrary(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tabButton = app.tabBars.buttons["Library"]
        if tabButton.waitForExistence(timeout: 2) {
            tabButton.tap()
            return
        }

        let sidebarButton = app.buttons["Library"]
        if sidebarButton.waitForExistence(timeout: 2) {
            sidebarButton.tap()
            return
        }

        let sidebarCell = app.cells.containing(.staticText, identifier: "Library").element
        if sidebarCell.waitForExistence(timeout: 2) {
            sidebarCell.tap()
            return
        }

        XCTFail("Library navigation item should exist", file: file, line: line)
    }

    @MainActor
    private func openInbox(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tabButton = app.tabBars.buttons["Inbox"]
        if tabButton.waitForExistence(timeout: 2) {
            tabButton.tap()
            return
        }

        let sidebarButton = app.buttons["Inbox"]
        if sidebarButton.waitForExistence(timeout: 2) {
            sidebarButton.tap()
            return
        }

        let sidebarCell = app.cells.containing(.staticText, identifier: "Inbox").element
        if sidebarCell.waitForExistence(timeout: 2) {
            sidebarCell.tap()
            return
        }

        XCTFail("Inbox navigation item should exist", file: file, line: line)
    }

    @MainActor
    private func tapAddPodcastButton(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let libraryAddButton = app.navigationBars["Library"].buttons["Add"]
        if libraryAddButton.waitForExistence(timeout: 2) {
            libraryAddButton.tap()
            return
        }

        let rootAddButton = app.navigationBars["OpenCast"].buttons["Add"]
        if rootAddButton.waitForExistence(timeout: 2) {
            rootAddButton.tap()
            return
        }

        let addButton = app.buttons["Add"].firstMatch
        if addButton.waitForExistence(timeout: 2) {
            addButton.tap()
            return
        }

        XCTFail("Add Podcast button should exist", file: file, line: line)
    }

    @MainActor
    private func waitForExternalTraceIfRequested(environmentKey: String) {
        guard let seconds = traceArmingSeconds(environmentKey: environmentKey), seconds > 0 else {
            return
        }

        XCTContext.runActivity(named: "Wait \(seconds)s for external trace") { _ in
            RunLoop.current.run(until: Date.now.addingTimeInterval(seconds))
        }
    }

    private func traceArmingSeconds(environmentKey: String) -> TimeInterval? {
        if let rawSeconds = ProcessInfo.processInfo.environment[environmentKey],
           let seconds = TimeInterval(rawSeconds) {
            return seconds
        }

        let fileURL = URL(fileURLWithPath: "/tmp/\(environmentKey)")
        guard let rawSeconds = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return nil
        }

        return TimeInterval(rawSeconds)
    }

    private func requireLongShowNotesColdStartProbe() throws {
        let isEnabled = ProcessInfo.processInfo.environment[Self.longShowNotesColdStartProbeEnvironmentKey] == "1"
        guard isEnabled || FileManager.default.fileExists(atPath: Self.longShowNotesColdStartProbeFilePath) else {
            throw XCTSkip("Set \(Self.longShowNotesColdStartProbeEnvironmentKey)=1 to run the long show-notes cold-start probe.")
        }
    }

    @MainActor
    private func debuggerAlmanacFirstEpisode(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.containing(.staticText, identifier: "Rubber Duck, Final Witness").firstMatch
        if button.waitForExistence(timeout: 2) {
            return button
        }

        return app.cells.containing(.staticText, identifier: "Rubber Duck, Final Witness").element
    }

    @MainActor
    private func openSettings(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tabButton = app.tabBars.buttons["Settings"]
        if tabButton.waitForExistence(timeout: 2) {
            tabButton.tap()
            return
        }

        let sidebarButton = app.buttons["Settings"]
        if sidebarButton.waitForExistence(timeout: 2) {
            sidebarButton.tap()
            return
        }

        let sidebarCell = app.cells.containing(.staticText, identifier: "Settings").element
        if sidebarCell.waitForExistence(timeout: 2) {
            sidebarCell.tap()
            return
        }

        XCTFail("Settings navigation item should exist", file: file, line: line)
    }

    @MainActor
    private func diagnosticsRow(in app: XCUIApplication, title: String, value: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, value)
        return app.staticTexts.matching(predicate).firstMatch
    }

    @MainActor
    private func elementContaining(label: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func waitForVoiceBoostProcessedFrames(
        in app: XCUIApplication,
        minProcessedFrames: Int,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let diagnostics = app.descendants(matching: .any)["Voice Boost Diagnostics"]
        assertExists(diagnostics, named: "Voice Boost diagnostics", timeout: timeout, file: file, line: line)

        let processedFramesAdvanced = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String
            else {
                return false
            }

            return self.voiceBoostCounter("processedFrames", from: value) >= minProcessedFrames
                && self.voiceBoostCounter("timedProcessCount", from: value) > 0
                && self.voiceBoostCounter("maxProcessDurationNanoseconds", from: value) > 0
                && self.voiceBoostCounter("sourceErrors", from: value) == 0
        }
        let expectation = XCTNSPredicateExpectation(predicate: processedFramesAdvanced, object: diagnostics)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        let value = diagnostics.value as? String ?? "nil"
        XCTAssertEqual(
            result,
            .completed,
            "Expected Voice Boost processedFrames >= \(minProcessedFrames) with timing counters and sourceErrors=0, got \(value)",
            file: file,
            line: line
        )

        guard let value = diagnostics.value as? String else {
            XCTFail("Voice Boost diagnostics value should be readable", file: file, line: line)
            return 0
        }
        return voiceBoostCounter("processedFrames", from: value)
    }

    private func voiceBoostCounter(_ name: String, from diagnosticsValue: String) -> Int {
        let prefix = "\(name)="
        for component in diagnosticsValue.split(separator: ";") {
            guard component.hasPrefix(prefix) else {
                continue
            }
            return Int(component.dropFirst(prefix.count)) ?? 0
        }
        return 0
    }

    @MainActor
    private func assertElementValueNotEqual(
        _ element: XCUIElement,
        _ disallowedValue: String,
        named name: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let valueChanged = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String
            else {
                return false
            }

            return value != disallowedValue
        }
        let expectation = XCTNSPredicateExpectation(predicate: valueChanged, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Expected \(name) value to differ from \(disallowedValue), got \(element.value as? String ?? "nil")",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertToggle(
        _ toggle: XCUIElement,
        isOn: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedValues = isOn ? ["1", "On", "true"] : ["0", "Off", "false"]
        let value = toggle.value as? String
        XCTAssertTrue(
            value.map { expectedValues.contains($0) } ?? false,
            "Expected toggle to be \(isOn ? "on" : "off"), got \(value ?? "nil")",
            file: file,
            line: line
        )
    }

    @MainActor
    private func tapToggle(
        _ toggle: XCUIElement,
        to isOn: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !toggleValue(toggle, matches: isOn) else {
            return
        }

        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        let expectedValues = isOn ? ["1", "On", "true"] : ["0", "Off", "false"]
        let changed = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String
            else {
                return false
            }
            return expectedValues.contains(value)
        }
        let expectation = XCTNSPredicateExpectation(predicate: changed, object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed, file: file, line: line)
    }

    @MainActor
    private func toggleValue(_ toggle: XCUIElement, matches isOn: Bool) -> Bool {
        let expectedValues = isOn ? ["1", "On", "true"] : ["0", "Off", "false"]
        guard let value = toggle.value as? String else {
            return false
        }
        return expectedValues.contains(value)
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<maxSwipes where !element.isHittable {
            app.swipeUp()
        }

        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    @MainActor
    private func scrollUntilMiniPlayerDoesNotCover(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 3
    ) {
        let miniPlayer = app.buttons["Open Now Playing"]
        for _ in 0..<maxSwipes where element.exists && miniPlayer.exists && element.frame.intersects(miniPlayer.frame) {
            app.swipeUp()
        }
    }

    @MainActor
    private func scrollUntilExists(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }

        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
    }
}
