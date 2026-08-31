import UIKit
import XCTest

final class OpenCastUITests: XCTestCase {
    // Keep these in sync with OpenCastUITestSeedData episode/feed IDs and the row identifier helpers.
    private static let seededEpisodeRowIdentifier = "episode-row-ui-test-episode-1"
    private static let seededDownloadSelectionRowIdentifier = "download-selection-row-ui-test-episode-1"
    private static let seededCompletedEpisodeRowIdentifier = "episode-row-ui-test-episode-completed"
    private static let seededQueuedEpisodeRowIdentifiers = (1...3).map {
        "episode-row-ui-test-queued-episode-\($0)"
    }
    private static let liveAdAnalysisEpisodeRowIdentifier = "episode-row-audio-illusion-that-proves-we-dont-experience-reality"
    private static let seededSubscriptionRowIdentifier = "subscription-row-https://example.com/ui-test-feed.xml"
    private static let soundLabTranscriptActionIdentifier = "Now Playing Sound Lab Transcript Action"
    private static let seedVoiceBoostModeEnvironmentKey = "OPENCAST_SEED_VOICE_BOOST_MODE"
    private static let seedAdDetectionModeEnvironmentKey = "OPENCAST_SEED_AD_DETECTION_MODE"
    private static let cloudAdDetectionModeValue = "cloud"
    private static let onDeviceAdDetectionModeValue = "onDevice"
    private static let adAnalysisClientTokenEnvironmentKey = "OPENCAST_AD_ANALYSIS_CLIENT_TOKEN"
    private static let adAnalysisBaseURLEnvironmentKey = "OPENCAST_AD_ANALYSIS_BASE_URL"
    private static let localAdAnalysisClientTokenFilePath = "/private/tmp/opencast-ad-analysis-client-token"
    private static let physicalAppAttestAdAnalysisProbeEnvironmentKey = "OPENCAST_RUN_PHYSICAL_APP_ATTEST_AD_ANALYSIS_UI_TESTS"
    private static let physicalAppAttestAdAnalysisProbeFilePath = "/tmp/opencast-run-physical-app-attest-ad-analysis-ui-tests"
    private static let liveAdAnalysisTranscriptPathEnvironmentKey = "OPENCAST_SEED_LIVE_AD_ANALYSIS_TRANSCRIPT_PATH"
    private static let liveAdAnalysisResponsePathEnvironmentKey = "OPENCAST_SEED_LIVE_AD_ANALYSIS_RESPONSE_PATH"
    private static let adFreePassPresentationOverrideEnvironmentKey = "OPENCAST_UI_TEST_AD_FREE_PASS_STAGE"
    private static let seedAdAnalysisSpanAtStartEnvironmentKey = "OPENCAST_SEED_AD_ANALYSIS_SPAN_AT_START"
    private static let soundLabLaunchHoldEnvironmentKey =
        "OPENCAST_UI_TEST_SOUND_LAB_LAUNCH_HOLD_MILLISECONDS"
    private static let perEpisodeVoiceBoostModeValue = "perEpisode"
    private static let playEpisodeTraceArmingSecondsEnvironmentKey = "OPENCAST_PLAY_EPISODE_TRACE_ARMING_SECONDS"
    private static let nowPlayingDismissTraceArmingSecondsEnvironmentKey = "OPENCAST_NOW_PLAYING_DISMISS_TRACE_ARMING_SECONDS"
    private static let coldStartTraceArmingSecondsEnvironmentKey = "OPENCAST_COLD_START_TRACE_ARMING_SECONDS"
    private static let manyArtworkTraceArmingSecondsEnvironmentKey = "OPENCAST_MANY_ARTWORK_TRACE_ARMING_SECONDS"
    private static let manyArtworkPerformanceProbeEnvironmentKey = "OPENCAST_RUN_MANY_ARTWORK_PREVIEW_PERF_UI_TESTS"
    private static let manyArtworkPerformanceProbeFilePath = "/tmp/opencast-run-many-artwork-preview-perf-ui-tests"
    private static let longShowNotesColdStartProbeEnvironmentKey = "OPENCAST_RUN_LONG_SHOW_NOTES_COLD_START_UI_TESTS"
    private static let longShowNotesColdStartProbeFilePath = "/tmp/opencast-run-long-show-notes-cold-start-ui-tests"
    private static let thisAmericanLifeReviewerPathProbeEnvironmentKey = "OPENCAST_RUN_TAL_REVIEWER_PATH_UI_TESTS"
    private static let thisAmericanLifeReviewerPathProbeFilePath = "/tmp/opencast-run-tal-reviewer-path-ui-tests"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryTabsAreAvailableOnCompactWidth() throws {
        let app = makeCompletedOnboardingApp()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        let inboxTab = app.tabBars.buttons["Inbox"]
        XCTAssertTrue(inboxTab.exists)
        XCTAssertTrue(inboxTab.isSelected)
        XCTAssertTrue(app.tabBars.buttons["Downloads"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
    }

    @MainActor
    func testSettingsShowsRemoteTranscriptionUnavailableRetry() throws {
        let app = makeCompletedOnboardingApp()
        app.launchArguments += [
            "-OPENCAST_REMOTE_TRANSCRIPTION_PURCHASE_FIXTURE",
            "unavailable",
        ]
        app.launch()

        openSettings(in: app)

        let header = app.staticTexts["Remote Transcription"]
        var swipes = 0
        while !header.waitForExistence(timeout: 5) && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(
            header.exists,
            "Remote Transcription section should remain discoverable when StoreKit is unavailable"
        )
        assertExists(app.buttons["Try Again"], named: "remote transcription retry action")
    }

    @MainActor
    func testRemoteTranscriptionIAPReviewScreenshot() throws {
        let app = makeSeededApp(forcesDarkMode: false, forcesLightMode: true)
        app.launchArguments += [
            "-OPENCAST_REMOTE_TRANSCRIPTION_PURCHASE_FIXTURE",
            "review-screenshot",
        ]
        app.launch()

        openSettings(in: app)
        let product = app.staticTexts["20 Transcription Hours"]
        scrollUntilExists(product, in: app, maxSwipes: 8)
        assertExists(app.staticTexts["Remote Transcription"], named: "Remote Transcription section")
        assertExists(app.staticTexts["Balance, 1 hr"], named: "fixture balance")
        assertExists(product, named: "20-hour product")
        assertExists(app.staticTexts["100 Transcription Hours"], named: "100-hour product")
        assertExists(
            app.buttons["Buy 20 Transcription Hours for $0.99"],
            named: "20-hour purchase button"
        )
        assertExists(
            app.buttons["Buy 100 Transcription Hours for $4.99"],
            named: "100-hour purchase button"
        )
        attachSmokeScreenshot(named: "remote_transcription_iap_review")
    }

    @MainActor
    func testEpisodeMenuShowsRemoteSurfacesOnFreshLaunchWithoutSettings() throws {
        // Launch-scoped gate resolution: remote surfaces
        // must appear in the episode menu on a fresh launch without Settings
        // ever mounting (the gate was previously resolved only from Settings' task).
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true
        )
        app.launchArguments.append("-OPENCAST_REMOTE_TRANSCRIPTION_DEV")
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        openEpisodeDetailFromContextMenu(inboxEpisode, in: app, named: "seeded inbox episode")

        let actionsButton = app.buttons["Episode Actions"].firstMatch
        assertExists(actionsButton, named: "Episode Actions menu", timeout: 8)
        actionsButton.tap()

        assertExists(app.buttons["Download"], named: "download action proving episode is not local")
        let remoteAction = app.descendants(matching: .any)["Transcribe Remotely"].firstMatch
        XCTAssertTrue(
            remoteAction.waitForExistence(timeout: 8),
            "Remote transcription menu entry should be present on fresh launch without opening Settings"
        )
    }

    @MainActor
    func testSeededEpisodeDiagnosticsSheetShowsSectionsAndReportActions() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true
        )
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        openEpisodeDetailFromContextMenu(inboxEpisode, in: app, named: "seeded inbox episode")

        let actionsButton = app.buttons["Episode Actions"].firstMatch
        assertExists(actionsButton, named: "Episode Actions menu", timeout: 8)
        actionsButton.tap()

        let diagnosticsEntry = app.buttons["Episode Diagnostics"].firstMatch
        assertExists(diagnosticsEntry, named: "Episode Diagnostics menu entry")
        diagnosticsEntry.tap()

        assertExists(
            app.navigationBars["Episode Diagnostics"].firstMatch,
            named: "diagnostics sheet",
            timeout: 8
        )
        assertExists(app.buttons["Refresh Diagnostics"].firstMatch, named: "refresh diagnostics action")
        assertExists(app.buttons["Copy Report"].firstMatch, named: "copy report action")
        assertExists(app.buttons["Share Report"].firstMatch, named: "share report action")
        assertExists(app.buttons["Download & Share MP3"].firstMatch, named: "download and share MP3 action")

        // The seeded transcript/analysis data and the explicit missing-data
        // state for the unseeded download coexist in one report; deeper
        // sections require scrolling the sheet list. LabeledContent rows
        // expose one combined "Label, Value" static text, so match by
        // containment.
        let missingDownloadRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "No download record.")
        ).firstMatch
        scrollDiagnosticsSheet(to: missingDownloadRow, in: app)
        assertExists(missingDownloadRow, named: "missing download state")
        let zoneMatrixHeader = app.staticTexts["Zone Matrix"].firstMatch
        scrollDiagnosticsSheet(to: zoneMatrixHeader, in: app)
        assertExists(zoneMatrixHeader, named: "zone matrix section")

        app.buttons["Done"].firstMatch.tap()
        assertExists(actionsButton, named: "episode detail after dismissing diagnostics", timeout: 8)
    }

    @MainActor
    func testSeededEpisodeDiagnosticsDownloadShareOpensActivitySheet() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsCompletedDownload: true
        )
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        // The shared context-menu helper expects a Download action, which the
        // seeded completed download replaces; open the detail directly.
        inboxEpisode.press(forDuration: 1.2)
        let detailsAction = app.buttons["View Episode Details"]
        assertExists(detailsAction, named: "seeded inbox episode details context action")
        detailsAction.tap()
        assertExists(app.buttons["Play Episode"], named: "seeded episode detail")

        let actionsButton = app.buttons["Episode Actions"].firstMatch
        assertExists(actionsButton, named: "Episode Actions menu", timeout: 8)
        actionsButton.tap()
        let diagnosticsEntry = app.buttons["Episode Diagnostics"].firstMatch
        assertExists(diagnosticsEntry, named: "Episode Diagnostics menu entry")
        diagnosticsEntry.tap()
        assertExists(
            app.navigationBars["Episode Diagnostics"].firstMatch,
            named: "diagnostics sheet",
            timeout: 8
        )

        let shareButton = app.buttons["Download & Share MP3"].firstMatch
        assertExists(shareButton, named: "download and share MP3 action")
        shareButton.tap()

        // The seeded completed download shares immediately; the activity
        // sheet's header carries the sanitized hard-link filename, proving
        // the share file preparation end to end.
        let shareHeader = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "UI Test Show - Deterministic UI Episode")
        ).firstMatch
        assertExists(shareHeader, named: "activity sheet with sanitized share filename", timeout: 10)
    }

    @MainActor
    private func scrollDiagnosticsSheet(to element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.exists {
            app.swipeUp()
        }
    }

    @MainActor
    func testSearchTabFindsSeededEpisodeAndRecordsRecentQuery() throws {
        let app = makeSeededApp(forcesDarkMode: false, forcesLightMode: true)
        app.launch()

        openSection("Search", in: app)
        let searchField = app.searchFields.firstMatch
        assertExists(searchField, named: "Search tab field")
        assertExists(app.keyboards.firstMatch, named: "keyboard opened by Search tab")
        searchField.typeText("Deterministic UI Episode\n")

        assertExists(seededEpisodeRow(in: app), named: "seeded episode search result", timeout: 20)

        searchField.tap()
        let clearButton = searchField.buttons["Clear text"].firstMatch
        assertExists(clearButton, named: "Search clear button")
        clearButton.tap()
        assertExists(app.staticTexts["Recently Searched"], named: "recent searches section")
        assertExists(app.buttons["Deterministic UI Episode"], named: "recorded recent search")
    }

    @MainActor
    func testSearchRevampSeededScopesEvidenceAndRelaunch() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsCompletedDownload: true,
            seedsCompletedTranscript: true
        )
        app.launchEnvironment["OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS"] =
            "noAccount"
        app.launchEnvironment["OPENCAST_UI_TEST_REFRESH_SEED_FEED"] = "1"
        app.launch()

        openLibrary(in: app)
        let refreshedSubscription = seededSubscriptionRow(in: app)
        assertExists(refreshedSubscription, named: "seeded show for feed refresh")
        refreshedSubscription.tap()
        let refreshActions = app.buttons["Podcast Actions"]
        assertExists(refreshActions, named: "podcast actions for feed refresh")
        refreshActions.tap()
        let refreshButton = app.buttons["Refresh"].firstMatch
        assertExists(refreshButton, named: "feed refresh action")
        refreshButton.tap()

        var searchField = openGlobalSearch(in: app)
        searchField.typeText("Refresh Boundary Signal")
        let refreshedResult = seededEpisodeRow(in: app)
        assertExists(
            refreshedResult,
            named: "refresh-updated global result",
            timeout: 20
        )
        XCTAssertTrue(refreshedResult.label.contains("Refresh Boundary Signal"))
        attachSmokeScreenshot(named: "search_revamp_feed_refresh")

        clearSearchFieldForRevampSmoke(searchField)
        searchField = openGlobalSearch(in: app)
        searchField.typeText("Determinstic UI Episode")
        assertExists(
            seededEpisodeRow(in: app),
            named: "typo-corrected global result",
            timeout: 20
        )

        clearSearchFieldForRevampSmoke(searchField)
        searchField = openGlobalSearch(in: app)
        searchField.typeText("missing replacement query")
        clearSearchFieldForRevampSmoke(searchField)
        searchField = openGlobalSearch(in: app)
        searchField.typeText("Seed Sponsor")
        assertExists(
            seededEpisodeRow(in: app),
            named: "transcript-only global result after rapid replacement",
            timeout: 20
        )
        attachSmokeScreenshot(named: "search_revamp_global_transcript")

        clearSearchFieldForRevampSmoke(searchField)
        assertExists(
            app.staticTexts["No Recent Searches"],
            named: "unchanged blank-query state"
        )

        app.terminate()
        app.launch()
        searchField = openGlobalSearch(in: app)
        searchField.typeText("Seed Sponsor")
        assertExists(
            seededEpisodeRow(in: app),
            named: "transcript-only result after relaunch",
            timeout: 20
        )

        app.terminate()
        app.launch()
        openLibrary(in: app)
        let subscription = seededSubscriptionRow(in: app)
        assertExists(subscription, named: "seeded show for scoped search")
        subscription.tap()
        let podcastActions = app.buttons["Podcast Actions"]
        assertExists(podcastActions, named: "podcast actions for scoped search")
        podcastActions.tap()
        app.buttons["Search"].firstMatch.tap()
        searchField = presentedSearchField(
            in: app,
            navigationBarTitle: "UI Test Show"
        )
        // Search scopes are presented only after the field has content on the
        // current iOS 26 search presentation.
        searchField.typeText("show notes")
        let showFullTextScope = app.buttons["Full Text"].firstMatch
        assertExists(showFullTextScope, named: "show full-text scope")
        showFullTextScope.tap()
        assertExists(
            seededEpisodeRow(in: app),
            named: "show-notes result in show scope",
            timeout: 20
        )

        app.terminate()
        app.launch()
        openSection("Downloads", in: app)
        let downloadSearch = app.navigationBars["Downloads"].buttons["Search"]
        assertExists(downloadSearch, named: "downloads search button")
        downloadSearch.tap()
        searchField = presentedSearchField(
            in: app,
            navigationBarTitle: "Downloads"
        )
        searchField.typeText("Seed Sponsor")
        let downloadFullTextScope = app.buttons["Full Text"].firstMatch
        assertExists(downloadFullTextScope, named: "downloads full-text scope")
        downloadFullTextScope.tap()
        assertExists(
            seededEpisodeRow(in: app),
            named: "transcript-only result in download scope",
            timeout: 20
        )
        attachSmokeScreenshot(named: "search_revamp_download_transcript")
    }

    @MainActor
    func testCompletedOnboardingEmptyLaunchShowsInboxLoadingThenEmpty() throws {
        let app = makeCompletedOnboardingApp(libraryLoadDelayMilliseconds: 6_000)
        app.launchEnvironment["OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS"] = "noAccount"
        app.launch()

        let inboxTab = app.tabBars.buttons["Inbox"]
        assertExists(inboxTab, named: "Inbox tab")
        XCTAssertTrue(inboxTab.isSelected)
        assertExists(app.descendants(matching: .any)["Inbox Loading"], named: "Inbox loading spinner")
        assertExists(app.staticTexts["Inbox Empty"], named: "empty Inbox after load", timeout: 15)
    }

    @MainActor
    func testFirstLaunchOnboardingScreenshotsOPMLSkipAndPodcastSetup() throws {
        let app = makeOnboardingApp(forcesDarkMode: true)
        app.launch()

        assertExists(app.staticTexts["Welcome to opencast!"], named: "onboarding welcome")
        assertExists(app.staticTexts["No third-party analytics"], named: "no third-party analytics pitch")
        assertExists(elementContaining(label: "View Source on GitHub", in: app), named: "source pitch link")
        assertExists(app.staticTexts["Tiny install"], named: "tiny install pitch")
        attachSmokeScreenshot(named: "onboarding_welcome_dark")

        app.buttons["Continue"].tap()
        assertExists(app.buttons["Import OPML"], named: "Import OPML button")
        assertExists(app.buttons["Skip"], named: "Skip OPML onboarding action")
        app.buttons["Apple Podcasts Export Shortcut"].tap()
        assertExists(
            app.staticTexts["This iCloud Shortcut helps export your Apple Podcasts subscriptions into an OPML file that opencast can import."],
            named: "Apple Podcasts Shortcut explainer"
        )
        assertExists(app.buttons["Open Shortcut"], named: "Open Shortcut link")
        attachSmokeScreenshot(named: "onboarding_opml_import_dark")

        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Find Podcasts"], named: "Find Podcasts onboarding screen")
        assertExists(app.textFields["Podcast or creator"], named: "onboarding podcast search field")
        assertExists(app.staticTexts["Sample Podcasts"], named: "sample podcasts section")
        assertExists(app.staticTexts["This American Life"], named: "This American Life sample")
        app.buttons["RSS"].tap()
        assertExists(app.textFields["RSS Feed URL"], named: "onboarding RSS feed field")
        assertExists(app.buttons["Paste"], named: "onboarding Paste button")
        let rssSubscribeButton = app.buttons["Onboarding RSS Subscribe"]
        assertExists(rssSubscribeButton, named: "onboarding RSS Subscribe button")
        XCTAssertGreaterThan(rssSubscribeButton.frame.width, 280)
        attachSmokeScreenshot(named: "onboarding_podcast_setup_rss_dark")
        app.segmentedControls["Add Podcast Mode"].buttons["Search"].tap()
        assertExists(app.textFields["Podcast or creator"], named: "onboarding podcast search field after returning to search")
        app.textFields["Podcast or creator"].tap()
        app.textFields["Podcast or creator"].typeText("history\n")
        assertExists(app.staticTexts["Find Podcasts"], named: "onboarding stays visible after keyboard search submit")
        XCTAssertFalse(app.buttons["Add This American Life"].exists)
        scrollUntilExists(app.staticTexts["The Rest Is Science"], in: app, maxSwipes: 2)
        assertExists(app.staticTexts["The Rest Is Science"], named: "The Rest Is Science sample")
        attachSmokeScreenshot(named: "onboarding_podcast_setup_dark")

        app.buttons["Continue"].tap()
        assertExists(app.staticTexts["Tiny Whisper Model"], named: "Tiny Whisper onboarding screen")
        let installTinyModelButton = app.buttons["Install Tiny Model"]
        assertExists(installTinyModelButton, named: "Install Tiny Model onboarding action")
        XCTAssertTrue(installTinyModelButton.isHittable, "Install Tiny Model should be visible without scrolling")
        attachSmokeScreenshot(named: "onboarding_tiny_whisper_setup_dark")
        installTinyModelButton.tap()
        assertExists(
            app.descendants(matching: .any)["Tiny Whisper Install Toast"],
            named: "Tiny Whisper install toast"
        )
        assertExists(app.staticTexts["New Episode Alerts"], named: "notification onboarding screen")
        assertExists(app.buttons["Enable Notifications"], named: "Enable Notifications onboarding action")
        attachSmokeScreenshot(named: "onboarding_notification_setup_dark")

        app.buttons["Done"].tap()
        assertExists(app.buttons["Add This American Life"], named: "fallback sample confirmation action")
        assertExists(
            elementContaining(label: "opencast will add This American Life", in: app),
            named: "fallback sample confirmation copy"
        )
    }

    @MainActor
    func testSettingsDebugRunOnboardingScreenshotsAndKeepsSubscriptions() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true
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
        assertExists(app.staticTexts["Welcome to opencast!"], named: "debug onboarding welcome")
        attachSmokeScreenshot(named: "settings_debug_onboarding_welcome_light")

        app.buttons["Continue"].tap()
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Find Podcasts"], named: "debug podcast setup")
        assertExists(app.textFields["Podcast or creator"], named: "debug onboarding podcast search field")
        assertExists(app.staticTexts["Your Podcasts"], named: "debug imported podcasts section")
        assertExists(app.staticTexts["UI Test Show"], named: "debug existing subscription")
        XCTAssertFalse(app.staticTexts["Sample Podcasts"].exists)
        attachSmokeScreenshot(named: "settings_debug_onboarding_podcast_setup_light")
        app.buttons["Continue"].tap()
        assertExists(app.staticTexts["Tiny Whisper Model"], named: "debug Tiny Whisper setup")
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["New Episode Alerts"], named: "debug notification setup")
        attachSmokeScreenshot(named: "settings_debug_onboarding_notification_setup_light")
        app.buttons["Done"].tap()

        openLibrary(in: app)
        assertExists(seededSubscriptionRow(in: app), named: "seeded subscription after debug onboarding")
    }

    @MainActor
    func testFirstTimeOnboardingNotificationPageDismissesOnboarding() throws {
        let app = makeOnboardingApp(forcesDarkMode: false, seedsLibrary: true)
        app.launch()

        assertExists(app.staticTexts["Welcome to opencast!"], named: "clean onboarding welcome", timeout: 20)
        assertExists(app.staticTexts["1 feed auto imported"], named: "iCloud auto-import notification", timeout: 10)
        attachSmokeScreenshot(named: "onboarding_imported_subscription_notice_light")
        app.buttons["Continue"].tap()
        assertExists(app.buttons["Skip"], named: "Skip OPML onboarding action")
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Find Podcasts"], named: "Find Podcasts onboarding screen")
        assertExists(app.staticTexts["Your Podcasts"], named: "imported podcasts onboarding section")
        assertExists(app.staticTexts["UI Test Show"], named: "imported subscription row")
        attachSmokeScreenshot(named: "onboarding_imported_podcast_setup_light")
        app.buttons["Continue"].tap()
        assertExists(app.staticTexts["Tiny Whisper Model"], named: "Tiny Whisper onboarding screen")
        let installTinyModelButton = app.buttons["Install Tiny Model"]
        assertExists(installTinyModelButton, named: "Install Tiny Model onboarding action")
        XCTAssertTrue(installTinyModelButton.isHittable, "Install Tiny Model should be visible without scrolling")
        installTinyModelButton.tap()
        assertExists(
            app.descendants(matching: .any)["Tiny Whisper Install Toast"],
            named: "Tiny Whisper install toast"
        )
        assertExists(app.staticTexts["New Episode Alerts"], named: "notification onboarding screen")
        app.buttons["Done"].tap()

        XCTAssertTrue(
            app.staticTexts["New Episode Alerts"].waitForNonExistence(timeout: 10),
            "Onboarding should dismiss after the final notification page."
        )
        openInbox(in: app)
        XCTAssertFalse(app.staticTexts["New Episode Alerts"].exists)
    }

    @MainActor
    func testForcedAppleSpeechDiagnosticsSectionScreenshots() throws {
        // Simulators render the Apple diagnostics surface through the DEBUG
        // fake-assets provider for screenshot + copy evidence, dark and light.
        for forcesDarkMode in [true, false] {
            let app = makeSeededApp(forcesDarkMode: forcesDarkMode, forcesLightMode: !forcesDarkMode)
            app.launchArguments.append("--opencast-apple-speech-fake-assets=installed")
            app.launchEnvironment["OPENCAST_APPLE_SPEECH_FAKE_ASSETS"] = "installed"
            app.launch()

            openSettings(in: app)
            scrollUntilExists(app.staticTexts["Transcription"], in: app)
            assertExists(app.staticTexts["Transcription"], named: "Whisper transcription settings section")
            let modelManagementAvailable = NSPredicate { object, _ in
                guard let app = object as? XCUIApplication else {
                    return false
                }
                return app.buttons["Install Fast Model"].exists
                    || app.buttons["Check Model"].exists
            }
            let modelManagementExpectation = XCTNSPredicateExpectation(
                predicate: modelManagementAvailable,
                object: app
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [modelManagementExpectation], timeout: 10),
                .completed,
                "Expected main Settings to expose Whisper model management."
            )
            XCTAssertFalse(app.buttons["Check Speech Assets"].exists)
            XCTAssertFalse(app.buttons["Fast"].exists)
            XCTAssertFalse(app.buttons["Accurate"].exists)
            attachSmokeScreenshot(named: forcesDarkMode ? "settings_whisper_transcription_dark" : "settings_whisper_transcription_light")

            let diagnosticsLink = app.buttons["Diagnostics"].firstMatch
            scrollUntilHittable(diagnosticsLink, in: app)
            diagnosticsLink.tap()
            scrollUntilExists(app.staticTexts["Apple Speech Assets"], in: app)
            assertExists(app.staticTexts["Apple Speech Assets"], named: "Apple speech diagnostics section")
            let installedStatus = elementContaining(label: "Installed", in: app)
            scrollUntilExists(installedStatus, in: app)
            assertExists(installedStatus, named: "Apple speech installed status")
            assertExists(app.buttons["Check Speech Assets"], named: "Check Speech Assets action")
            scrollUntilExists(app.staticTexts["Whisper Model"], in: app)
            assertExists(app.staticTexts["Whisper Model"], named: "Whisper model diagnostics")
            assertExists(app.buttons["Fast"], named: "Fast picker in Diagnostics")
            assertExists(app.buttons["Accurate"], named: "Accurate picker in Diagnostics")
            attachSmokeScreenshot(named: forcesDarkMode ? "diagnostics_transcription_dark" : "diagnostics_transcription_light")
            app.terminate()
        }
    }

    @MainActor
    func testSeededInboxEpisodeCanOpenPlayer() throws {
        let app = makeSeededApp()
        app.launch()

        let inboxTab = app.tabBars.buttons["Inbox"]
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 5))
        XCTAssertTrue(inboxTab.isSelected)
        let inboxEpisode = seededEpisodeRow(in: app)
        XCTAssertTrue(inboxEpisode.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Deterministic UI Episode"].exists)
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        XCTAssertTrue(playbackProgress(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists || app.buttons["Play"].exists)

        openCurrentEpisodeDetailFromNowPlaying(in: app)
        let playbackControl = episodePlaybackControl(in: app)
        assertExists(playbackControl, named: "episode playback control")
        assertExists(app.buttons["Pause Episode"], named: "Pause Episode control")
        XCTAssertTrue(app.staticTexts["Show Notes"].exists)

        playbackControl.tap()
        assertExists(app.buttons["Play Episode"], named: "Play Episode after pausing")
        episodePlaybackControl(in: app).tap()
        assertExists(app.buttons["Pause Episode"], named: "Pause Episode after resuming")

        let artwork = app.buttons["Episode Artwork"]
        assertHittable(artwork, named: "episode artwork")
        artwork.tap()
        let zoomableArtwork = app.descendants(matching: .any)
            .matching(identifier: "Zoomable Episode Artwork")
            .firstMatch
        assertHittable(zoomableArtwork, named: "zoomable episode artwork")
        XCTAssertEqual(zoomableArtwork.elementType, .image)
        XCTAssertEqual(zoomableArtwork.label, "Artwork for Deterministic UI Episode")
        XCTAssertEqual(zoomableArtwork.value as? String, "100%")
        zoomableArtwork.pinch(withScale: 2, velocity: 1)
        let resetZoom = app.buttons["Reset Zoom"]
        assertExists(resetZoom, named: "Reset Zoom after magnifying artwork")
        zoomableArtwork.swipeLeft()
        resetZoom.tap()
        assertDoesNotExist(resetZoom, named: "Reset Zoom at default scale")
        tapBackButton(in: app)
        assertExists(episodePlaybackControl(in: app), named: "episode detail after closing artwork")
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
        assertExists(inboxEpisode, named: "seeded inbox episode after failed playback")
    }

    @MainActor
    func testSeededInboxEpisodeTapPlaysAndExpandsNowPlaying() throws {
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

        openCurrentEpisodeDetailFromNowPlaying(in: app)
        swipeBack(in: app)
        let inboxTab = app.tabBars.buttons["Inbox"]
        assertExists(inboxTab, named: "Inbox tab after episode detail Back")
        XCTAssertTrue(inboxTab.isSelected)
        assertExists(seededEpisodeRow(in: app), named: "Inbox after episode detail Back")

        let miniPlayer = app.buttons["Open Now Playing"]
        assertExists(miniPlayer, named: "mini-player after episode detail Back")
        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
        let podcastTitle = nowPlayingOverlay(in: app).buttons["Now Playing Podcast Title"].firstMatch
        assertHittable(podcastTitle, named: "Now Playing podcast title")
        podcastTitle.tap()
        assertExists(app.navigationBars["UI Test Show"], named: "show detail from Now Playing")
        assertExists(app.staticTexts["Episodes"], named: "show episodes section")

        swipeBack(in: app)
        assertExists(inboxTab, named: "Inbox tab after show detail Back")
        XCTAssertTrue(inboxTab.isSelected)
        assertExists(seededEpisodeRow(in: app), named: "Inbox after show detail Back")
    }

    @MainActor
    func testSeededInboxEpisodeContextMenuPeekOpensEpisodeDetail() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "inbox episode before Go to Show")
        inboxEpisode.press(forDuration: 1.2)
        let goToShow = app.buttons["Go to Show"]
        assertHittable(goToShow, named: "inbox Go to Show context action")
        goToShow.tap()
        assertExists(
            app.descendants(matching: .any)["Podcast Hero Header"],
            named: "show reached from the context action"
        )
        tapBackButton(in: app)

        openEpisodeDetailFromContextMenu(
            inboxEpisode,
            in: app,
            named: "inbox episode"
        )

        let showLink = app.buttons["UI Test Show"]
        assertHittable(showLink, named: "episode show link")
        showLink.tap()
        assertExists(app.descendants(matching: .any)["Podcast Hero Header"], named: "show detail")
    }

    @MainActor
    func testSeededInboxEpisodeOffersPlayedSwipeAction() throws {
        let app = makeSeededApp()
        app.launch()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertHittable(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.swipeRight()

        assertHittable(app.buttons["Mark Played"], named: "Inbox Mark Played swipe action")
    }

    @MainActor
    func testSeededPodcastEpisodeContextMenuPeekOpensEpisodeDetail() throws {
        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        let podcastEpisode = seededEpisodeRow(in: app)
        openEpisodeDetailFromContextMenu(
            podcastEpisode,
            in: app,
            named: "podcast episode",
            expectsGoToShow: false
        )
    }

    @MainActor
    func testSeededInboxRendersLocalArtworkPreviewOnFirstScreenshot() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsArtworkPreview: true,
            artworkVariant: "placeholder"
        )
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode with preview")
        let firstRowScreenshot = inboxEpisode.screenshot()
        let attachment = XCTAttachment(screenshot: firstRowScreenshot)
        attachment.name = "inbox_first_paint_artwork_preview_row"
        attachment.lifetime = .keepAlways
        add(attachment)

        let pixelSummary = try artworkPreviewPixelSummary(from: firstRowScreenshot)
        XCTAssertGreaterThan(pixelSummary.previewPixels, 100)
        XCTAssertGreaterThan(pixelSummary.previewPixels, pixelSummary.placeholderPixels * 8)
        attachSmokeScreenshot(named: "inbox_first_paint_artwork_preview")
    }

    @MainActor
    func testSeededInboxRendersManyVariedLocalArtworkPreviews() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsArtworkPreview: true,
            seedsVariedArtworkPreviews: true,
            extraFeedCount: 80,
            artworkVariant: "placeholder"
        )
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        waitForExternalTraceIfRequested(environmentKey: Self.manyArtworkTraceArmingSecondsEnvironmentKey)
        app.tabBars.buttons["Inbox"].tap()

        let firstRow = seededEpisodeRow(in: app)
        assertExists(firstRow, named: "first seeded inbox episode with varied preview")
        let firstPixelSummary = try dominantArtworkPreviewPixelSummary(for: firstRow)
        XCTAssertGreaterThan(firstPixelSummary.previewPixels, firstPixelSummary.placeholderPixels * 8)

        let deeperRow = seededExtraEpisodeRow(in: app, index: 24)
        scrollUntilVisible(deeperRow, in: app, maxSwipes: 10)
        let deeperPixelSummary = try dominantArtworkPreviewPixelSummary(for: app)
        XCTAssertGreaterThan(deeperPixelSummary.previewPixels, deeperPixelSummary.placeholderPixels * 8)
        attachSmokeScreenshot(named: "inbox_many_varied_artwork_previews")
    }

    @MainActor
    func testOptInSeededManyArtworkPreviewInboxFirstPaintPerformance() throws {
        try requireManyArtworkPerformanceProbe()

        measureSeededInboxFirstPaintPerformance(
            seedsArtworkPreview: true,
            seedsVariedArtworkPreviews: true
        )
    }

    @MainActor
    func testOptInSeededManyPlaceholderInboxFirstPaintPerformance() throws {
        try requireManyArtworkPerformanceProbe()

        measureSeededInboxFirstPaintPerformance(
            seedsArtworkPreview: false,
            seedsVariedArtworkPreviews: false
        )
    }

    @MainActor
    private func measureSeededInboxFirstPaintPerformance(
        seedsArtworkPreview: Bool,
        seedsVariedArtworkPreviews: Bool
    ) {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsArtworkPreview: seedsArtworkPreview,
            seedsVariedArtworkPreviews: seedsVariedArtworkPreviews,
            extraFeedCount: 80,
            artworkVariant: "placeholder"
        )
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(
            metrics: [
                XCTClockMetric(),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app)
            ],
            options: options
        ) {
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
            app.tabBars.buttons["Inbox"].tap()
            XCTAssertTrue(seededEpisodeRow(in: app).waitForExistence(timeout: 5))
            app.terminate()
        }
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
    func testSeededCompletionRemovesCollapsedMiniPlayer() throws {
        let app = makeSeededApp(audioDurationSeconds: 15)
        app.launch()

        openSeededNowPlaying(in: app)
        dismissNowPlayingOverlay(in: app)

        let miniPlayer = app.buttons["Open Now Playing"]
        XCTAssertTrue(
            miniPlayer.waitForNonExistence(timeout: 25),
            "Natural completion should remove the collapsed mini-player."
        )
        let overlay = nowPlayingOverlay(in: app)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
        assertDoesNotExist(
            finishedPlayback(in: overlay),
            named: "Finished presentation inside collapsed overlay"
        )
        assertDoesNotExist(
            finishedPlayback(in: app),
            named: "app-scoped collapsed Finished presentation"
        )
    }

    @MainActor
    func testSeededExpandedCompletionReplaysAndDismissesWithoutMiniPlayer() throws {
        let app = makeSeededApp(audioDurationSeconds: 15)
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        let finished = finishedPlayback(in: overlay)
        assertExists(finished, named: "expanded Finished state", timeout: 25)
        XCTAssertEqual(finished.label, "Finished")
        let replay = overlay.buttons["Replay"]
        let done = overlay.buttons["Done"]
        assertExists(replay, named: "Replay action")
        assertExists(done, named: "Done action")
        XCTAssertGreaterThanOrEqual(replay.frame.width, 44)
        XCTAssertGreaterThanOrEqual(replay.frame.height, 44)
        XCTAssertGreaterThanOrEqual(done.frame.width, 44)
        XCTAssertGreaterThanOrEqual(done.frame.height, 44)
        assertDoesNotExist(playbackProgress(in: app), named: "progress control after completion")
        assertDoesNotExist(overlay.buttons["Up Next"], named: "Up Next control after completion")
        assertDoesNotExist(app.buttons["Open Now Playing"], named: "mini-player behind Finished state")

        replay.tap()
        XCTAssertTrue(
            finished.waitForNonExistence(timeout: 5),
            "Replay should return the overlay to live Now Playing."
        )
        assertExists(playbackProgress(in: app), named: "progress control after Replay")
        assertExists(finished, named: "Finished state after Replay completes", timeout: 25)
        assertDoesNotExist(app.buttons["Open Now Playing"], named: "mini-player after second completion")

        done.tap()
        XCTAssertTrue(
            overlay.waitForNonExistence(timeout: 5),
            "Done should finish the existing card dismissal before unmounting the overlay."
        )
        assertDoesNotExist(app.buttons["Open Now Playing"], named: "mini-player after Done")
    }

    @MainActor
    func testSeededCompletionDuringCancelledDismissDragReturnsFinishedCard() throws {
        let app = makeSeededApp(audioDurationSeconds: 8)
        app.launchArguments.append("--opencast-frame-probe")
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        holdNowPlayingDismissDrag(in: app, endY: 0.32, holdDuration: 10)

        let finished = finishedPlayback(in: overlay)
        assertHittable(finished, named: "Finished card after cancelled completion drag", timeout: 5)
        assertHittable(overlay.buttons["Replay"], named: "Replay after cancelled completion drag")
        // Completion must land while the drag is held; otherwise this only
        // proves an ordinary drag on an already-Finished card springs back.
        let summary = captureFramePacingSummary(
            in: app,
            expectedSessions: 1,
            containing: "dismiss-drag-ended"
        )
        assertEventOrder(
            ["dismiss-drag-start", "playback-finished", "dismiss-drag-ended"],
            in: summary,
            named: "completion during held dismiss drag"
        )

        overlay.buttons["Done"].tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testSeededCompletionDuringDismissDragCompletesDismissal() throws {
        let app = makeSeededApp(audioDurationSeconds: 8)
        app.launchArguments.append("--opencast-frame-probe")
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        holdNowPlayingDismissDrag(in: app, endY: 0.58, holdDuration: 10)

        XCTAssertTrue(
            overlay.waitForNonExistence(timeout: 5),
            "A completion drag above threshold should finish dismissal."
        )
        assertDoesNotExist(finishedPlayback(in: app), named: "Finished card after completed dismissal")
        assertHittable(app.tabBars.buttons["Library"], named: "interactive Library tab after completion dismissal")
        let summary = captureFramePacingSummary(
            in: app,
            expectedSessions: 1,
            containing: "card-dismissed"
        )
        assertEventOrder(
            ["dismiss-drag-start", "playback-finished", "dismiss-drag-ended", "card-dismissed"],
            in: summary,
            named: "completion during held dismiss drag that dismisses"
        )
    }

    @MainActor
    func testSeededCompletionDuringExitAnimationLeavesInteractiveTabs() throws {
        let app = makeSeededApp(
            audioDurationSeconds: 15,
            skipIntroSeconds: 13.4
        )
        app.launchArguments.append("--opencast-frame-probe")
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        holdNowPlayingDismissDrag(
            in: app,
            endY: 0.58,
            holdDuration: 0.05,
            velocity: .fast
        )

        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
        assertHittable(app.tabBars.buttons["Library"], named: "interactive Library tab after in-flight completion")
        let summary = captureFramePacingSummary(in: app, expectedSessions: 1)
        assertEventOrder(
            ["dismiss-drag-ended", "playback-finished", "card-dismissed"],
            in: summary,
            named: "completion during dismissal exit"
        )
    }

    @MainActor
    func testSeededNearEndCompletionDuringEntranceShowsFinishedCard() throws {
        let app = makeSeededApp(
            audioDurationSeconds: 15,
            skipIntroSeconds: 14.4
        )
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        let finished = finishedPlayback(in: overlay)
        assertHittable(finished, named: "Finished card after near-end entrance", timeout: 5)
        assertHittable(overlay.buttons["Replay"], named: "Replay after near-end entrance")
    }

    @MainActor
    func testSeededMiniPlayerTabAccessorySurvivesInboxScrollAndExpands() throws {
        let app = makeSeededApp(extraFeedCount: 12)
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)

        let miniPlayer = app.buttons["Open Now Playing"]
        let tabBar = app.tabBars.firstMatch
        assertExists(miniPlayer, named: "mini-player before Inbox scroll")
        assertExists(tabBar, named: "tab bar before Inbox scroll")
        XCTAssertTrue(miniPlayer.isHittable)

        scrollUntilExists(seededExtraEpisodeRow(in: app, index: 8), in: app, maxSwipes: 4)

        assertExists(miniPlayer, named: "mini-player after Inbox scroll")
        assertExists(tabBar, named: "tab bar after Inbox scroll")
        XCTAssertTrue(miniPlayer.isHittable)
        attachSmokeScreenshot(named: "mini_player_tab_accessory_inbox_scrolled")

        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
    }

    @MainActor
    func testOptInSeededLongShowNotesColdStartInboxEpisodeTapPlaysAndExpandsNowPlaying() throws {
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
    func testSeededEpisodeTapWhileListeningPlaysAndExpandsNowPlaying() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)

        assertExists(inboxEpisode, named: "seeded inbox episode after returning to Inbox")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control after second episode tap")
        attachSmokeScreenshot(named: "episode_tap_while_listening_expanded_now_playing")
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
        scrollUntilExists(completedEpisode, in: app)
        assertExists(completedEpisode, named: "completed podcast episode row")
        openEpisodeDetailFromContextMenu(
            completedEpisode,
            in: app,
            named: "completed podcast episode",
            expectsGoToShow: false
        )

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
        scrollUntilExists(completedEpisode, in: app)
        assertExists(completedEpisode, named: "completed podcast episode row")
        openEpisodeDetailFromContextMenu(
            completedEpisode,
            in: app,
            named: "completed podcast episode",
            expectsGoToShow: false
        )
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
        scrollUntilExists(completedEpisode, in: app)
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
        let libraryAddPodcastButton = app.buttons["Library Empty Add Podcast"]
        let librarySampleButton = app.buttons["Library Empty Try This American Life"]
        assertExists(libraryAddPodcastButton, named: "empty library Add Podcast action")
        assertExists(librarySampleButton, named: "empty library sample action")
        XCTAssertLessThan(libraryAddPodcastButton.frame.height, 80)
        XCTAssertLessThan(librarySampleButton.frame.height, 80)
        XCTAssertGreaterThan(libraryAddPodcastButton.frame.width, 180)
        XCTAssertGreaterThan(librarySampleButton.frame.width, 180)
        XCTAssertLessThan(abs(libraryAddPodcastButton.frame.midX - app.staticTexts["No Subscriptions"].frame.midX), 4)
        XCTAssertLessThan(abs(librarySampleButton.frame.midX - app.staticTexts["No Subscriptions"].frame.midX), 4)
        attachSmokeScreenshot(named: "library_after_swipe_remove")

        openInbox(in: app)
        assertExists(app.staticTexts["Inbox Empty"], named: "empty inbox after removal")
        let inboxAddPodcastButton = app.buttons["Inbox Empty Add Podcast"]
        assertExists(inboxAddPodcastButton, named: "empty inbox Add Podcast action")
        XCTAssertLessThan(inboxAddPodcastButton.frame.height, 80)
        XCTAssertGreaterThan(inboxAddPodcastButton.frame.width, 180)
        XCTAssertLessThan(abs(inboxAddPodcastButton.frame.midX - app.staticTexts["Inbox Empty"].frame.midX), 4)
        attachSmokeScreenshot(named: "inbox_after_library_swipe_remove")
    }

    @MainActor
    func testSeededPodcastPullDownOpensSearch() throws {
        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        let hero = app.descendants(matching: .any)["Podcast Hero Header"]
        assertExists(hero, named: "podcast hero before pull-down search")
        assertDoesNotExist(app.searchFields.firstMatch, named: "podcast search field before pull-down")

        pullDownToSearch(in: app)

        let searchField = app.searchFields.firstMatch
        assertExists(searchField, named: "podcast search field after pull-down")
        XCTAssertTrue(hero.waitForNonExistence(timeout: 5), "podcast hero should hide when pull-down opens search")

        searchField.typeText("Deterministic UI Episode")
        assertHittable(seededEpisodeRow(in: app), named: "pull-down search result without scrolling")

        let closeButton = app.buttons["Close"].firstMatch
        assertExists(closeButton, named: "podcast search close button after pull-down")
        closeButton.tap()
        assertExists(hero, named: "podcast hero after canceling pull-down search")
        assertDoesNotExist(app.searchFields.firstMatch, named: "podcast search field after canceling pull-down")
    }

    @MainActor
    func testSeededPodcastSearchKeepsResultsFrontAndCenter() throws {
        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        let hero = app.descendants(matching: .any)["Podcast Hero Header"]
        assertExists(hero, named: "podcast hero before search")
        assertDoesNotExist(app.searchFields.firstMatch, named: "inactive podcast search field")

        let actionsButton = app.buttons["Podcast Actions"]
        assertExists(actionsButton, named: "podcast actions menu")
        actionsButton.tap()
        app.buttons["Search"].firstMatch.tap()

        let searchField = app.searchFields.firstMatch
        assertExists(searchField, named: "podcast episode search field")
        XCTAssertTrue(hero.waitForNonExistence(timeout: 5))

        searchField.typeText("Deterministic UI Episode")
        let result = seededEpisodeRow(in: app)
        assertHittable(result, named: "podcast episode search result without scrolling")

        let closeButton = app.buttons["Close"].firstMatch
        assertExists(closeButton, named: "podcast search close button with query")
        closeButton.tap()
        assertExists(hero, named: "podcast hero after closing populated search")
        assertDoesNotExist(app.searchFields.firstMatch, named: "podcast search field after populated close")
        assertHittable(actionsButton, named: "podcast actions after closing populated search")

        actionsButton.tap()
        app.buttons["Search"].firstMatch.tap()

        let reopenedSearchField = app.searchFields.firstMatch
        assertExists(reopenedSearchField, named: "reopened podcast episode search field")
        reopenedSearchField.typeText("Deterministic")
        reopenedSearchField.tap()
        let clearButton = reopenedSearchField.buttons["Clear text"].firstMatch
        assertExists(clearButton, named: "podcast search clear button")
        clearButton.tap()
        assertDoesNotExist(hero, named: "podcast hero after clearing search")

        let clearedSearchCloseButton = app.buttons["Close"].firstMatch
        assertExists(clearedSearchCloseButton, named: "podcast search close button after clearing")
        clearedSearchCloseButton.tap()
        assertExists(hero, named: "podcast hero after canceling search")
        assertDoesNotExist(app.searchFields.firstMatch, named: "podcast search field after cleared close")
        assertExists(
            app.buttons["Sort Episodes, Newest First"],
            named: "podcast sort control after canceling search"
        )
        assertExists(
            app.buttons["Filter Episodes, All Episodes"],
            named: "podcast filter control after canceling search"
        )
    }

    @MainActor
    func testSeededPodcastAutoDetectToggleConfirmsAndEnables() throws {
        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        let actionsButton = app.buttons["Podcast Actions"]
        assertExists(actionsButton, named: "podcast actions menu")
        actionsButton.tap()

        let toggle = app.buttons["Automatically Detect Ads"]
        assertExists(toggle, named: "Automatically Detect Ads toggle")
        attachSmokeScreenshot(named: "podcast_actions_auto_detect_toggle")
        toggle.tap()

        // Enabling routes through the standing-opt-in confirmation with the
        // play-trigger contract copy; disabling below is immediate.
        let confirmButton = app.sheets.buttons["Turn On"].firstMatch
        assertExists(confirmButton, named: "auto-detect confirmation action")
        assertExists(
            elementContaining(label: "analyzed for ads when you play them", in: app),
            named: "auto-detect confirmation contract copy"
        )
        attachSmokeScreenshot(named: "podcast_auto_detect_confirmation")
        confirmButton.tap()

        actionsButton.tap()
        assertExists(toggle, named: "Automatically Detect Ads toggle after enabling")
        toggle.tap()
        assertDoesNotExist(app.sheets.firstMatch, named: "confirmation dialog after disabling")
    }

    @MainActor
    func testSeededPodcastPlaybackSkipSettingsValidateSaveAndReset() throws {
        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        openPodcastPlaybackSettings(in: app)
        let navigationBar = app.navigationBars["Skip Intro & Outro"]
        let introField = app.textFields["Skip Intro Duration"]
        let outroField = app.textFields["Skip Outro Duration"]
        assertExists(navigationBar.buttons["Cancel"], named: "playback settings cancel action")
        assertExists(navigationBar.buttons["Save"], named: "playback settings save action")
        assertExists(introField, named: "skip intro duration field")
        assertExists(outroField, named: "skip outro duration field")
        XCTAssertTrue(introField.label.contains("Skip Intro duration"))
        XCTAssertTrue(outroField.label.contains("Skip Outro duration"))
        XCTAssertEqual(introField.value as? String, "0:00")
        XCTAssertEqual(outroField.value as? String, "0:00")

        let introStepper = app.steppers["Adjust Skip Intro"]
        assertHittable(introStepper, named: "native skip intro stepper")
        let increaseIntro = introStepper.coordinate(
            withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)
        )
        let decreaseIntro = introStepper.coordinate(
            withNormalizedOffset: CGVector(dx: 0.80, dy: 0.5)
        )
        increaseIntro.tap()
        XCTAssertEqual(introField.value as? String, "0:05")
        decreaseIntro.tap()
        XCTAssertEqual(introField.value as? String, "0:00")

        replaceText(in: introField, with: "1:99")
        navigationBar.buttons["Save"].tap()
        assertExists(
            app.staticTexts["Podcast Playback Settings Error"],
            named: "invalid playback duration error"
        )

        replaceText(in: introField, with: "1:05")
        assertDoesNotExist(
            app.staticTexts["Podcast Playback Settings Error"],
            named: "stale validation error after editing"
        )
        replaceText(in: outroField, with: "0:30")
        XCTAssertEqual(introField.value as? String, "1:05")
        XCTAssertEqual(outroField.value as? String, "0:30")
        navigationBar.buttons["Save"].tap()
        assertDoesNotExist(navigationBar, named: "playback settings after save")

        openPodcastPlaybackSettings(in: app)
        let reopenedNavigationBar = app.navigationBars["Skip Intro & Outro"]
        let reopenedIntroField = app.textFields["Skip Intro Duration"]
        let reopenedOutroField = app.textFields["Skip Outro Duration"]
        assertExists(reopenedIntroField, named: "reopened skip intro duration field")
        XCTAssertEqual(reopenedIntroField.value as? String, "1:05")
        XCTAssertEqual(reopenedOutroField.value as? String, "0:30")

        let resetBoth = app.buttons["Reset Both"]
        assertHittable(resetBoth, named: "reset both playback skips")
        resetBoth.tap()
        XCTAssertEqual(reopenedIntroField.value as? String, "0:00")
        XCTAssertEqual(reopenedOutroField.value as? String, "0:00")
        reopenedNavigationBar.buttons["Save"].tap()
        assertDoesNotExist(reopenedNavigationBar, named: "playback settings after reset save")

        openPodcastPlaybackSettings(in: app)
        XCTAssertEqual(app.textFields["Skip Intro Duration"].value as? String, "0:00")
        XCTAssertEqual(app.textFields["Skip Outro Duration"].value as? String, "0:00")
    }

    @MainActor
    func testSeededAutoDetectPlayTriggerEnqueuesAutoPass() throws {
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true,
            seedsEpisodeProgress: true
        )
        app.launch()

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()

        let actionsButton = app.buttons["Podcast Actions"]
        assertExists(actionsButton, named: "podcast actions menu")
        actionsButton.tap()
        let toggle = app.buttons["Automatically Detect Ads"]
        assertExists(toggle, named: "Automatically Detect Ads toggle")
        toggle.tap()
        let confirmButton = app.sheets.buttons["Turn On"].firstMatch
        assertExists(confirmButton, named: "auto-detect confirmation action")
        confirmButton.tap()

        // Playing the unanalyzed episode of the opted-in show enqueues an
        // auto pass; playing the analyzed one enqueues nothing. The queue's
        // run log in the app container is the proof artifact — this test is
        // the deterministic driver for it.
        let unanalyzedRow = seededCompletedEpisodeRow(in: app)
        scrollUntilExists(unanalyzedRow, in: app)
        assertExists(unanalyzedRow, named: "unanalyzed seeded episode row")
        unanalyzedRow.tap()
        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)

        let analyzedRow = seededEpisodeRow(in: app)
        assertExists(analyzedRow, named: "analyzed seeded episode row")
        analyzedRow.tap()
        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)
    }

    @MainActor
    func testSeededAdDetectionIndicatorOpensQueueScreenWithConsentAffordance() throws {
        let app = makeSeededApp()
        // A stored mode skips the first-tap cloud-or-device dialog (its own
        // coverage: testDetectAdsFirstTapPromptsForModeAndRemembersOnDeviceChoice).
        app.launchEnvironment[Self.seedAdDetectionModeEnvironmentKey] = Self.onDeviceAdDetectionModeValue
        app.launch()

        let indicator = app.buttons["Ad Detection Queue Indicator"]
        assertDoesNotExist(indicator, named: "indicator while the queue is idle")

        let episodeRow = seededEpisodeRow(in: app)
        assertExists(episodeRow, named: "seeded inbox episode row")
        episodeRow.press(forDuration: 1.2)
        let detectAction = app.buttons["Detect Ads"].firstMatch
        assertExists(detectAction, named: "Detect Ads context action")
        detectAction.tap()

        // On the simulator the pass deterministically pauses at whisper model
        // consent (Apple transcriber unavailable), a stable paused state.
        assertExists(indicator, named: "indicator after enqueue", timeout: 10)
        attachSmokeScreenshot(named: "adqueue_indicator_paused_consent")
        indicator.tap()

        assertExists(app.navigationBars["Ad Detection"], named: "queue screen title")
        let consentButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Download Model")
        ).firstMatch
        assertExists(consentButton, named: "model consent affordance", timeout: 10)
        assertDoesNotExist(
            app.buttons["Continue in Background"],
            named: "Continue in Background while paused for consent"
        )
        attachSmokeScreenshot(named: "adqueue_screen_consent")
    }

    @MainActor
    func testDetectAdsFirstTapPromptsForModeAndRemembersOnDeviceChoice() throws {
        let app = makeSeededApp()
        app.launchArguments.append("-OPENCAST_REMOTE_TRANSCRIPTION_DEV")
        app.launch()

        let episodeRow = seededEpisodeRow(in: app)
        assertExists(episodeRow, named: "seeded inbox episode row")
        episodeRow.press(forDuration: 1.2)
        let detectAction = app.buttons["Detect Ads"].firstMatch
        assertExists(detectAction, named: "Detect Ads context action")
        detectAction.tap()

        // First manual tap with no stored mode: the cloud-or-device dialog.
        let deviceChoice = app.buttons["Detect On This Device"]
        assertExists(deviceChoice, named: "mode dialog device choice", timeout: 10)
        assertExists(app.buttons["Use Cloud Credits"], named: "mode dialog cloud choice")
        attachSmokeScreenshot(named: "admode_dialog_first_tap")
        deviceChoice.tap()

        // The chosen on-device pass runs (parks at whisper model consent on
        // the simulator) — no second confirmation.
        let indicator = app.buttons["Ad Detection Queue Indicator"]
        assertExists(indicator, named: "indicator after device choice", timeout: 10)
        assertDoesNotExist(
            app.buttons["Use Cloud Credits"],
            named: "mode dialog after the choice ran"
        )

        // Settings reflects the remembered device-local choice. (Cross-
        // relaunch persistence is covered at the store layer — UI-test
        // launches deliberately use an in-memory store.) The section sits
        // below the fold of the lazy settings list, so scroll it into
        // existence, and the collapsed picker may expose the selection as
        // its value rather than its label.
        openSettings(in: app)
        let modeSelection = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "On This Device",
                "On This Device"
            )
        ).firstMatch
        scrollUntilExists(modeSelection, in: app, maxSwipes: 12)
        assertExists(modeSelection, named: "Detect Ads mode in Settings")
        attachSmokeScreenshot(named: "admode_settings_on_device")
    }

    @MainActor
    func testCloudUnavailableDetectPassOffersOneTapOnDeviceFallback() throws {
        let app = makeSeededApp()
        app.launchArguments.append("-OPENCAST_REMOTE_TRANSCRIPTION_DEV")
        app.launchArguments += [
            "-OPENCAST_REMOTE_TRANSCRIPTION_PURCHASE_FIXTURE", "unavailable",
        ]
        app.launch()

        let episodeRow = seededEpisodeRow(in: app)
        assertExists(episodeRow, named: "seeded inbox episode row")
        episodeRow.press(forDuration: 1.2)
        let detectAction = app.buttons["Detect Ads"].firstMatch
        assertExists(detectAction, named: "Detect Ads context action")
        detectAction.tap()

        let cloudChoice = app.buttons["Use Cloud Credits"]
        assertExists(cloudChoice, named: "mode dialog cloud choice", timeout: 10)
        cloudChoice.tap()

        // The unresolved backend fails the viability precheck immediately:
        // the queue finishes with a cloud-unavailable outcome — never a
        // silent switch to on-device.
        let indicator = app.buttons["Ad Detection Queue Indicator"]
        assertExists(indicator, named: "indicator after cloud-unavailable outcome", timeout: 10)
        indicator.tap()
        assertExists(app.navigationBars["Ad Detection"], named: "queue screen title")
        let fallback = app.buttons["Detect on this device instead"]
        assertExists(fallback, named: "one-tap on-device fallback", timeout: 10)
        attachSmokeScreenshot(named: "adqueue_cloud_unavailable_fallback")

        // The explicit fallback runs a fresh on-device pass, which parks at
        // whisper model consent on the simulator.
        fallback.tap()
        let consentButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Download Model")
        ).firstMatch
        assertExists(consentButton, named: "on-device pass model consent", timeout: 15)
        attachSmokeScreenshot(named: "adqueue_fallback_running_on_device")
    }

    @MainActor
    func testSeededAdDetectionQueueCapDeferredShowsBannerAndRetry() throws {
        let app = makeSeededApp(seedsCompletedTranscript: true)
        app.launchEnvironment["OPENCAST_ADANALYSIS_FORCE_CAP"] = "1"
        // DEBUG bearer auth so the simulator's missing App Attest doesn't
        // fail the pass before the forced cap rejection fires (no network
        // happens — the force hook throws first).
        app.launchEnvironment["OPENCAST_AD_ANALYSIS_CLIENT_TOKEN"] = "ui-test-forced-cap"
        app.launch()

        let episodeRow = seededEpisodeRow(in: app)
        assertExists(episodeRow, named: "seeded inbox episode row")
        episodeRow.press(forDuration: 1.2)
        let detectAction = app.buttons["Detect Ads"].firstMatch
        assertExists(detectAction, named: "Detect Ads context action")
        detectAction.tap()

        // Transcript reuse goes straight to analysis; the forced 429 cap
        // rejection pauses the queue in capDeferred.
        let indicator = app.buttons["Ad Detection Queue Indicator"]
        assertExists(indicator, named: "indicator after cap deferral", timeout: 10)
        indicator.tap()

        assertExists(app.navigationBars["Ad Detection"], named: "queue screen title")
        assertExists(
            elementContaining(label: "Daily detection limit reached", in: app),
            named: "cap deferral banner",
            timeout: 10
        )
        assertExists(app.buttons["Retry"], named: "cap deferral Retry affordance")
        assertDoesNotExist(
            app.buttons["Continue in Background"],
            named: "Continue in Background while cap-deferred"
        )
        attachSmokeScreenshot(named: "adqueue_screen_cap_deferred")
    }

    @MainActor
    func testOptInSlowWorkerAdDetectionQueueRunningTwoEpisodes() throws {
        // Requires the slow local analysis server (never responds) so the
        // analyzing stage stays live: OPENCAST_UI_SLOW_AD_ANALYSIS_URL points
        // at it (e.g. http://127.0.0.1:8977).
        let slowBaseURL = try requireEnvironmentValue(
            "OPENCAST_UI_SLOW_AD_ANALYSIS_URL",
            skipMessage: "Set OPENCAST_UI_SLOW_AD_ANALYSIS_URL to a stalling local worker to run the live queue smoke."
        )
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsEpisodeProgress: true
        )
        app.launchEnvironment["OPENCAST_AD_ANALYSIS_BASE_URL"] = slowBaseURL
        app.launchEnvironment["OPENCAST_AD_ANALYSIS_CLIENT_TOKEN"] = "ui-test-slow-worker"
        app.launch()

        // Opt the show into auto-detect from its detail menu.
        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")
        libraryPodcast.tap()
        app.buttons["Podcast Actions"].tap()
        let toggle = app.buttons["Automatically Detect Ads"]
        assertExists(toggle, named: "Automatically Detect Ads toggle")
        toggle.tap()
        let confirmButton = app.sheets.buttons["Turn On"].firstMatch
        assertExists(confirmButton, named: "auto-detect confirmation action")
        confirmButton.tap()

        // Play the transcript-seeded episode: its auto pass reuses the
        // transcript and hangs in the live analyzing stage on the stalled
        // worker. Then play the second episode so it queues behind it.
        let analyzedSeedRow = seededEpisodeRow(in: app)
        assertExists(analyzedSeedRow, named: "transcript-seeded episode row")
        analyzedSeedRow.tap()
        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)

        let secondRow = seededCompletedEpisodeRow(in: app)
        assertExists(secondRow, named: "second seeded episode row")
        secondRow.tap()
        assertNowPlayingOverlay(in: app)
        dismissNowPlayingOverlay(in: app)

        openInbox(in: app)
        let indicator = app.buttons["Ad Detection Queue Indicator"]
        assertExists(indicator, named: "running queue indicator", timeout: 10)
        attachSmokeScreenshot(named: "adqueue_indicator_running")
        indicator.tap()

        assertExists(app.navigationBars["Ad Detection"], named: "queue screen title")
        assertExists(
            elementContaining(label: "Analyzing promos and ads", in: app),
            named: "live analyzing stage text",
            timeout: 10
        )
        assertExists(
            elementContaining(label: "Queued — 1 ahead", in: app),
            named: "second episode queue position"
        )
        // Play-triggered auto passes never arm, so the explicit
        // continue-in-background affordance is offered.
        assertExists(
            app.buttons["Continue in Background"],
            named: "Continue in Background while running un-armed"
        )
        attachSmokeScreenshot(named: "adqueue_screen_running_two_episodes")
    }

    @MainActor
    func testSeededAdDetectionQueueShowsFinishedFailures() throws {
        let app = makeSeededApp(seedsBadAudioURL: true)
        // A stored mode skips the first-tap cloud-or-device dialog (its own
        // coverage: testDetectAdsFirstTapPromptsForModeAndRemembersOnDeviceChoice).
        app.launchEnvironment[Self.seedAdDetectionModeEnvironmentKey] = Self.onDeviceAdDetectionModeValue
        app.launch()

        let episodeRow = seededEpisodeRow(in: app)
        assertExists(episodeRow, named: "seeded inbox episode row")
        episodeRow.press(forDuration: 1.2)
        let detectAction = app.buttons["Detect Ads"].firstMatch
        assertExists(detectAction, named: "Detect Ads context action")
        detectAction.tap()

        // The bad audio URL fails the download immediately; the drain ends
        // and the indicator shows its brief finished state (failure-tinted).
        let indicator = app.buttons["Ad Detection Queue Indicator"]
        assertExists(indicator, named: "finished indicator", timeout: 10)
        attachSmokeScreenshot(named: "adqueue_indicator_finished_tinted")
        indicator.tap()

        assertExists(app.navigationBars["Ad Detection"], named: "queue screen title")
        assertExists(app.staticTexts["Finished"], named: "finished section header", timeout: 10)
        assertExists(
            app.descendants(matching: .any)
                .matching(identifier: "ad-detection-queue-row-ui-test-episode-1")
                .firstMatch,
            named: "failed episode outcome row"
        )
        attachSmokeScreenshot(named: "adqueue_screen_finished_failure")
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
        assertExists(app.buttons["Open Now Playing"], named: "mini-player after playing library episode")
        assertExists(app.staticTexts["Episodes"], named: "podcast detail after dismissing Now Playing")
        assertExists(seededEpisodeRow(in: app), named: "podcast episode row after playing episode")
        attachSmokeScreenshot(named: "compact_podcast_detail_after_episode_play")
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
        app.launchArguments.append("--opencast-frame-probe")
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        RunLoop.current.run(until: Date.now.addingTimeInterval(2))
        waitForExternalTraceIfRequested(
            environmentKey: Self.nowPlayingDismissTraceArmingSecondsEnvironmentKey
        )
        dragDismissNowPlayingOverlayFromArtwork(in: app)
        XCTAssertTrue(nowPlayingOverlay(in: app).waitForNonExistence(timeout: 5))
        assertExists(app.buttons["Open Now Playing"], named: "mini-player after content-area dismiss")
        let summary = captureFramePacingSummary(in: app, expectedSessions: 2)
        XCTAssertTrue(summary.contains("dismiss-drag-start"), "expected warmed dismissal frame data")
    }

    @MainActor
    func testSeededNowPlayingCanDismissAfterBackgroundForeground() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        RunLoop.current.run(until: Date.now.addingTimeInterval(1.5))
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date.now.addingTimeInterval(2))
        app.activate()

        assertNowPlayingOverlay(in: app)
        dragDismissNowPlayingOverlayFromArtwork(in: app)
        XCTAssertTrue(nowPlayingOverlay(in: app).waitForNonExistence(timeout: 5))
        assertExists(app.buttons["Open Now Playing"], named: "mini-player after foreground dismiss")
    }

    @MainActor
    func testSeededNowPlayingArtworkSlideOpensSoundLabPanel() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        revealNowPlayingSoundLab(in: app)

        assertNowPlayingOverlay(in: app)
        assertExists(nowPlayingSoundLabPanel(in: app), named: "Now Playing Sound Lab panel")
        assertExists(app.switches["Voice Boost"], named: "Voice Boost Sound Lab toggle")
        XCTAssertFalse(app.buttons["Smart Speed"].exists)
        XCTAssertFalse(app.buttons["Skip Intros"].exists)
        XCTAssertFalse(app.buttons["Show Alerts"].exists)
    }

    @MainActor
    func testSeededNowPlayingArtworkSlideClosesSoundLabPanel() throws {
        let app = makeSeededApp()
        app.launch()

        assertExists(app.tabBars.buttons["Library"], named: "Library tab")
        app.tabBars.buttons["Inbox"].tap()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        revealNowPlayingSoundLab(in: app)
        assertExists(nowPlayingSoundLabPanel(in: app), named: "Now Playing Sound Lab panel")

        closeNowPlayingSoundLab(in: app)

        assertNowPlayingOverlay(in: app)
        XCTAssertTrue(nowPlayingSoundLabPanel(in: app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.switches["Voice Boost"].exists)
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
        revealNowPlayingSoundLab(in: app)
        assertExists(nowPlayingSoundLabPanel(in: app), named: "Now Playing Sound Lab panel")

        nowPlayingArtwork(in: app).tap()

        assertNowPlayingOverlay(in: app)
        XCTAssertTrue(nowPlayingSoundLabPanel(in: app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.switches["Voice Boost"].exists)
    }

    @MainActor
    func testSeededNowPlayingArtworkTapOpensSoundLabPanel() throws {
        let app = makeSeededApp()
        app.launch()

        openSeededNowPlaying(in: app)
        nowPlayingArtwork(in: app).tap()

        assertNowPlayingOverlay(in: app)
        assertExists(nowPlayingSoundLabPanel(in: app), named: "Now Playing Sound Lab panel")
        assertExists(app.switches["Voice Boost"], named: "Voice Boost Sound Lab toggle")
    }

    @MainActor
    func testSeededSoundLabAdActionAcknowledgesBeforeHeldLaunchPreparation() throws {
        let app = makeSeededApp(seedsCompletedTranscript: true)
        app.launchArguments.append("-OPENCAST_REMOTE_TRANSCRIPTION_DEV")
        app.launchEnvironment[Self.soundLabLaunchHoldEnvironmentKey] =
            optionalEnvironmentValue(Self.soundLabLaunchHoldEnvironmentKey) ?? "5000"
        app.launchEnvironment[Self.adAnalysisClientTokenEnvironmentKey] =
            "ui-test-held-preparation"
        app.launch()

        openSeededNowPlayingSoundLab(in: app)

        let voiceBoost = app.switches["Voice Boost"]
        let adAction = app.buttons.matching(identifier: "Skip Promos & Ads").firstMatch
        let remoteAction = app.buttons.matching(
            identifier: Self.soundLabTranscriptActionIdentifier
        ).firstMatch
        for (control, name) in [
            (voiceBoost, "Voice Boost"),
            (adAction, "Skip Promos & Ads"),
            (remoteAction, "Show Transcript")
        ] {
            assertExists(control, named: "\(name) Sound Lab control")
            if name == "Show Transcript" {
                XCTAssertEqual(control.label, name)
            }
            XCTAssertTrue(control.isHittable, "\(name) should be hittable")
            XCTAssertGreaterThanOrEqual(
                control.frame.height,
                43.99,
                "\(name) should keep the 44-point tap target"
            )
        }
        for title in ["Skip Promos & Ads", "Show Transcript"] {
            let label = app.staticTexts[title]
            assertExists(label, named: "complete \(title) label")
            let intrinsicWidth = (title as NSString).size(
                withAttributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline)
                ]
            ).width
            XCTAssertGreaterThanOrEqual(
                label.frame.width + 1,
                intrinsicWidth,
                "\(title) should receive enough width to render without truncation"
            )
        }

        adAction.tap()

        let accepted = NSPredicate(format: "value CONTAINS[c] %@", "Queued")
        expectation(for: accepted, evaluatedWith: adAction)
        waitForExpectations(timeout: 2)
        XCTAssertFalse(adAction.isEnabled)
        XCTAssertTrue(
            app.staticTexts["Skip Promos & Ads"].exists,
            "The stable action title should not reflow while accepted"
        )
    }

    @MainActor
    func testSeededNowPlayingSoundLabRemoteTranscriptionPresentsEstimateSheet() throws {
        let app = makeSeededApp()
        app.launchArguments.append("-OPENCAST_REMOTE_TRANSCRIPTION_DEV")
        app.launchEnvironment[Self.seedAdDetectionModeEnvironmentKey] = Self.cloudAdDetectionModeValue
        app.launch()

        openSeededNowPlayingSoundLab(in: app)
        let remoteRow = app.buttons.matching(
            identifier: Self.soundLabTranscriptActionIdentifier
        ).firstMatch
        assertExists(remoteRow, named: "Transcribe Remotely Sound Lab row")
        XCTAssertEqual(remoteRow.label, "Transcribe Remotely")
        remoteRow.tap()

        assertExists(app.navigationBars["Remote Transcription"], named: "consumption estimate sheet")
        assertExists(app.buttons["Start"], named: "estimate sheet Start action")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Remote Transcription"].waitForNonExistence(timeout: 5),
            "Cancelling the estimate sheet should dismiss it without starting"
        )
    }

    @MainActor
    func testSeededCompletedTranscriptSoundLabOpensTranscript() throws {
        let app = makeSeededApp(seedsCompletedTranscript: true)
        app.launchArguments.append("-OPENCAST_REMOTE_TRANSCRIPTION_DEV")
        app.launchEnvironment[Self.seedAdDetectionModeEnvironmentKey] = Self.cloudAdDetectionModeValue
        app.launch()

        openSeededNowPlayingSoundLab(in: app)
        assertDoesNotExist(
            app.buttons["Transcribe Remotely"],
            named: "cloud transcription action after transcript completion"
        )
        let showTranscript = app.buttons.matching(
            identifier: Self.soundLabTranscriptActionIdentifier
        ).firstMatch
        assertHittable(showTranscript, named: "Show Transcript Sound Lab row")
        XCTAssertEqual(showTranscript.label, "Show Transcript")
        showTranscript.tap()

        assertExists(app.staticTexts["Transcript"], named: "transcript sheet title")
        assertExists(
            app.buttons["Welcome to a deterministic transcript."],
            named: "seeded transcript line"
        )
    }

    @MainActor
    func testSeededLocalSoundLabTranscriptionCompletesAndOpensTranscript() throws {
        let app = makeSeededApp(
            seedsCompletedDownload: true,
            completesTranscriptRequests: true
        )
        app.launch()

        openSeededNowPlayingSoundLab(in: app)
        let transcriptAction = app.buttons.matching(
            identifier: Self.soundLabTranscriptActionIdentifier
        ).firstMatch
        assertHittable(transcriptAction, named: "local Sound Lab transcript action")
        XCTAssertEqual(transcriptAction.label, "Transcribe")
        transcriptAction.tap()

        assertExists(
            app.descendants(matching: .any)["Transcription Progress Toast"],
            named: "local transcription progress toast"
        )
        expectation(
            for: NSPredicate(format: "label == %@", "Show Transcript"),
            evaluatedWith: transcriptAction
        )
        waitForExpectations(timeout: 10)
        assertHittable(transcriptAction, named: "completed Sound Lab transcript action")
        transcriptAction.tap()

        assertExists(app.staticTexts["Transcript"], named: "transcript sheet title")
        assertExists(
            app.buttons["Deterministic UI request transcript."],
            named: "generated transcript line"
        )
    }

    @MainActor
    func testSeededCloudResolvingSoundLabCannotStartLocalTranscription() throws {
        let app = makeSeededApp(
            seedsCompletedDownload: true,
            completesTranscriptRequests: true
        )
        app.launchArguments += [
            "-OPENCAST_REMOTE_TRANSCRIPTION_PURCHASE_FIXTURE",
            "delayed-availability",
        ]
        app.launchEnvironment[Self.seedAdDetectionModeEnvironmentKey] = Self.cloudAdDetectionModeValue
        app.launch()

        openSeededNowPlayingSoundLab(in: app)
        let transcriptAction = app.buttons.matching(
            identifier: Self.soundLabTranscriptActionIdentifier
        ).firstMatch
        assertExists(transcriptAction, named: "cloud availability checking action")
        XCTAssertEqual(transcriptAction.label, "Transcribe Remotely")
        XCTAssertFalse(transcriptAction.isEnabled)
        XCTAssertTrue(
            transcriptAction.value.debugDescription.localizedCaseInsensitiveContains("checking"),
            "The disabled remote action should expose its availability check"
        )

        transcriptAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertDoesNotExist(
            app.descendants(matching: .any)["Transcription Progress Toast"],
            named: "local transcription toast while cloud availability is unresolved",
            timeout: 1
        )
        assertDoesNotExist(
            app.navigationBars["Remote Transcription"],
            named: "remote estimate before cloud availability resolves",
            timeout: 1
        )
    }

    @MainActor
    func testSeededNowPlayingAdFreePassControlStateScreenshots() throws {
        // The fixed-footprint row never shows progress text or "Working";
        // in-flight stages keep the stable title and expose status through
        // the accessibility value.
        let variants: [(stage: String, buttonLabel: String, statusFragment: String)] = [
            ("idle", "Skip Promos & Ads", "Ready to mark"),
            ("consent", "Download Model", "Speech model needed"),
            ("downloading", "Skip Promos & Ads", "Downloading episode"),
            ("installing", "Skip Promos & Ads", "Downloading speech model"),
            ("checking", "Skip Promos & Ads", "Checking speech model"),
            ("model-busy", "Skip Promos & Ads", "Speech model is not ready"),
            ("transcribing", "Skip Promos & Ads", "Transcribing"),
            ("analyzing", "Skip Promos & Ads", "Analyzing promos"),
            ("completed", "Reanalyze", "2 zones marked"),
            ("outdated", "Skip Promos & Ads", "Outdated — run again"),
            ("interrupted", "Resume", "Transcript interrupted"),
            ("failed", "Retry", "Daily promo/ad analysis limit reached"),
            ("unavailable", "Skip Promos & Ads", "No episode playing")
        ]

        for variant in variants {
            captureAdFreePassControlScreenshot(
                stage: variant.stage,
                buttonLabel: variant.buttonLabel,
                statusFragment: variant.statusFragment,
                screenshotName: "ad_free_pass_\(variant.stage)"
            )
        }
    }

    @MainActor
    func testSeededLandscapeNowPlayingAdFreePassControlLayoutScreenshots() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer {
            XCUIDevice.shared.orientation = .portrait
        }

        let variants: [(stage: String, buttonLabel: String, statusFragment: String)] = [
            ("consent", "Download Model", "Speech model needed"),
            ("installing", "Skip Promos & Ads", "Downloading speech model"),
            ("transcribing", "Skip Promos & Ads", "Transcribing"),
            ("failed", "Retry", "Daily promo/ad analysis limit reached")
        ]

        for variant in variants {
            captureAdFreePassControlScreenshot(
                stage: variant.stage,
                buttonLabel: variant.buttonLabel,
                statusFragment: variant.statusFragment,
                screenshotName: "ad_free_pass_landscape_\(variant.stage)"
            )
        }
    }

    @MainActor
    func testSeededAutoSkipPromosAndAdsShowsPillAndJumpsAcrossZone() throws {
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true
        )
        app.launch()

        openSeededNowPlaying(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control")
        assertExists(autoSkipPill(in: app), named: "auto-skip feedback pill", timeout: 8)
        let elapsed = waitForPlaybackElapsed(progress, atLeast: 8.8, timeout: 8)

        XCTAssertLessThan(
            elapsed,
            15,
            "Seeded auto-skip should jump to the 4-9s zone end early, not merely arrive by normal playback."
        )
        attachSmokeScreenshot(named: "seeded_auto_skip_pill_and_position_jump")
    }

    @MainActor
    func testSeededSpanAtStartAutoSkipStartsAtZoneEnd() throws {
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsAdAnalysisSpanAtStart: true
        )
        app.launch()

        openSeededNowPlaying(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control")
        let elapsed = waitForPlaybackElapsed(progress, atLeast: 3.8, timeout: 3.5)

        XCTAssertLessThan(
            elapsed,
            8,
            "Span-at-start seed should begin at the 0-4s zone end before ordinary playback could advance far beyond it."
        )
        attachSmokeScreenshot(named: "seeded_span_at_start_auto_skip")
    }

    @MainActor
    func testSeededAutoSkipToggleOffLeavesZonesVisibleAndSkippingInert() throws {
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true
        )
        app.launch()

        openSettings(in: app)
        let autoSkipToggle = autoSkipSettingsToggle(in: app)
        scrollUntilHittable(autoSkipToggle, in: app)
        assertToggle(autoSkipToggle, isOn: true)
        tapToggle(autoSkipToggle, to: false)

        openSeededNowPlaying(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control")
        let elapsedInZone = waitForPlaybackElapsed(progress, in: 4.2..<8.8, timeout: 8)

        assertDoesNotExist(autoSkipPill(in: app), named: "auto-skip feedback pill while disabled", timeout: 1)
        XCTAssertLessThan(elapsedInZone, 8.8)
        attachSmokeScreenshot(named: "seeded_auto_skip_disabled_passes_through_zone")
    }

    @MainActor
    func testSeededStaleAdAnalysisSkipsNothingAndOffersRerun() throws {
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsStaleAdAnalysis: true
        )
        app.launchEnvironment[Self.adAnalysisClientTokenEnvironmentKey] = ""
        app.launch()

        openSeededNowPlaying(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control")
        _ = waitForPlaybackElapsed(progress, in: 4.2..<8.8, timeout: 8)
        assertDoesNotExist(autoSkipPill(in: app), named: "auto-skip feedback pill for stale analysis", timeout: 1)

        revealNowPlayingSoundLab(in: app)
        assertExists(nowPlayingSoundLabPanel(in: app), named: "Now Playing Sound Lab panel")
        let passButton = app.buttons.matching(identifier: "Skip Promos & Ads").firstMatch
        assertExists(passButton, named: "stale-analysis pass re-run button")
        XCTAssertTrue(passButton.label.contains("Skip Promos & Ads"))
        XCTAssertTrue(
            ((passButton.value as? String) ?? "").contains("Outdated — run again"),
            "stale-analysis re-run status should surface as the row's accessibility value"
        )
        attachSmokeScreenshot(named: "seeded_stale_ad_analysis_offers_rerun")
    }

    @MainActor
    func testSeededAutoSkipPillTapUndoesSkipAndZonePlaysThrough() throws {
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true
        )
        app.launch()

        openSeededNowPlaying(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control")
        let pill = autoSkipPill(in: app)
        assertExists(pill, named: "auto-skip feedback pill", timeout: 8)
        // The pill is a button wrapping a label; both carry the identifier, so
        // tap the button element specifically.
        app.buttons["Skipped promo"].firstMatch.tap()

        // The undo seek lands at the zone start (4s) with .scrub intent: the
        // zone must play through once instead of re-skipping.
        let elapsedInZone = waitForPlaybackElapsed(progress, in: 4.2..<8.8, timeout: 6)
        XCTAssertLessThan(elapsedInZone, 8.8, "Undo should land back inside the 4-9s zone.")
        assertDoesNotExist(pill, named: "auto-skip pill after undo (no re-skip)", timeout: 1)
        _ = waitForPlaybackElapsed(progress, atLeast: 9.2, timeout: 8)
        attachSmokeScreenshot(named: "seeded_auto_skip_pill_undo_plays_through")
    }

    @MainActor
    func testSeededOutdatedPolicyAnalysisSkipsNothingAndOffersRerun() throws {
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsOutdatedPolicyAdAnalysis: true
        )
        app.launchEnvironment[Self.adAnalysisClientTokenEnvironmentKey] = ""
        app.launch()

        openSeededNowPlaying(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control")
        _ = waitForPlaybackElapsed(progress, in: 4.2..<8.8, timeout: 8)
        assertDoesNotExist(
            autoSkipPill(in: app),
            named: "auto-skip feedback pill for outdated-policy analysis",
            timeout: 1
        )

        revealNowPlayingSoundLab(in: app)
        assertExists(nowPlayingSoundLabPanel(in: app), named: "Now Playing Sound Lab panel")
        let outdatedPassButton = app.buttons.matching(identifier: "Skip Promos & Ads").firstMatch
        assertExists(outdatedPassButton, named: "outdated-policy pass re-run button")
        XCTAssertTrue(
            ((outdatedPassButton.value as? String) ?? "").contains("Outdated — run again"),
            "outdated-policy re-run status should surface as the row's accessibility value"
        )
        attachSmokeScreenshot(named: "seeded_outdated_policy_ad_analysis_offers_rerun")
    }

    @MainActor
    func testSeededLowConfidenceAnalysisRendersDimmedZoneWithoutAutoSkip() throws {
        let app = makeSeededApp(
            seedsCompletedTranscript: true,
            seedsLowConfidenceAdAnalysis: true
        )
        app.launch()

        openSeededNowPlaying(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control")

        // The sub-floor spans are display-only: playback passes straight
        // through 4-9s with no pill and no jump.
        let elapsedInZone = waitForPlaybackElapsed(progress, in: 4.2..<8.8, timeout: 8)
        XCTAssertLessThan(elapsedInZone, 8.8)
        assertDoesNotExist(
            autoSkipPill(in: app),
            named: "auto-skip feedback pill for display-only zone",
            timeout: 1
        )
        // Screenshot once the thumb has cleared the first zone so both dimmed
        // zones (4-9s and 100-160s) are visible on the bar.
        _ = waitForPlaybackElapsed(progress, atLeast: 10, timeout: 6)
        attachSmokeScreenshot(named: "seeded_low_confidence_dimmed_zone_no_auto_skip")
    }

    /// Device proof leg: drives the REAL app container (no seeding) on
    /// a simulator that already holds the bugged-pod episode with a completed
    /// live `promo_ad_breaks_v2` analysis. Verifies the intro-pod auto-skip on
    /// the actual bug-report audio and the pill-tap undo returning into the
    /// pod. Opt-in because it depends on that pre-arranged container state.
    @MainActor
    func testOptInRealLibraryBugEpisodeAutoSkipAndPillUndoProof() throws {
        guard optionalEnvironmentValue("OPENCAST_RUN_STEP4_BUG_EPISODE_UNDO_PROOF") == "1" else {
            throw XCTSkip("Set OPENCAST_RUN_STEP4_BUG_EPISODE_UNDO_PROOF=1 with the bugged-pod episode prepared in the real simulator container.")
        }

        let app = XCUIApplication()
        app.launch()

        // Load a different episode first: while the bugged episode is the
        // live player session, lifecycle flushes re-persist its position and
        // defeat Clear Progress.
        let otherRow = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND identifier BEGINSWITH %@",
                "This American Life",
                "episode-row"
            )
        ).firstMatch
        assertExists(otherRow, named: "decoy episode row", timeout: 10)
        otherRow.tap()
        let nowPlayingCard = app.scrollViews["Now Playing"].firstMatch
        assertExists(nowPlayingCard, named: "Now Playing for decoy episode", timeout: 10)
        nowPlayingCard.swipeDown(velocity: .fast)
        RunLoop.current.run(until: Date.now.addingTimeInterval(1.0))

        let episodeRow = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND identifier BEGINSWITH %@",
                "TAFS World Cup episode",
                "episode-row"
            )
        ).firstMatch
        assertExists(episodeRow, named: "bugged-pod episode row", timeout: 10)
        // A plain row tap starts playback; the context menu reaches the detail
        // view without touching the saved position.
        episodeRow.press(forDuration: 1.0)
        let viewDetails = app.buttons["View Episode Details"].firstMatch
        assertExists(viewDetails, named: "View Episode Details menu item", timeout: 5)
        viewDetails.tap()

        // Reset progress so playback starts ahead of the intro pod (0:51-2:21).
        let actionsButton = app.buttons["Episode Actions"].firstMatch
        assertExists(actionsButton, named: "Episode Actions menu", timeout: 8)
        actionsButton.tap()
        attachSmokeScreenshot(named: "auto_skip_bug_episode_actions_menu")
        let clearProgress = app.descendants(matching: .any)["Clear Progress"].firstMatch
        if clearProgress.waitForExistence(timeout: 3) {
            clearProgress.tap()
            // The menu action opens a confirmation dialog whose destructive
            // "Clear Progress" button performs the actual reset.
            let confirmClear = app.buttons["Clear Progress"].firstMatch
            assertExists(confirmClear, named: "Clear Progress confirmation", timeout: 5)
            confirmClear.tap()
            RunLoop.current.run(until: Date.now.addingTimeInterval(1.0))
        } else {
            XCTFail("Clear Progress menu item not found; cannot start ahead of the intro pod.")
        }

        // With the decoy episode holding the live session, the cleared
        // progress sticks; Play Episode loads the bugged episode from 0:00.
        let playButton = app.buttons["Play Episode"].firstMatch
        assertExists(playButton, named: "Play Episode button", timeout: 8)
        let dismissDeadline = Date.now.addingTimeInterval(6)
        while !playButton.isHittable, Date.now < dismissDeadline {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.5))
        }
        playButton.tap()

        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control", timeout: 10)
        let startElapsed = waitForPlaybackElapsed(progress, in: 0..<45, timeout: 8)
        XCTAssertLessThan(startElapsed, 45, "Playback must start ahead of the intro pod.")

        // The intro pod starts at ~0:51; the auto-skip jumps to ~2:21. Tap
        // the pill immediately — it auto-dismisses 2.5s after appearing.
        let pill = app.buttons["Skipped promo"].firstMatch
        assertExists(pill, named: "auto-skip pill on the intro pod", timeout: 75)
        pill.tap()
        attachSmokeScreenshot(named: "auto_skip_bug_episode_intro_auto_skip_pill_tapped")
        // Undo returns into the pod and plays through without re-skipping.
        // This device's live analysis marks the intro pod at ~0:50-2:10, so
        // anything under 2:00 is unambiguously "back inside".
        let backInside = waitForPlaybackElapsed(progress, in: 49..<120, timeout: 8)
        attachSmokeScreenshot(named: "auto_skip_bug_episode_pill_undo_back_inside_pod")
        XCTAssertLessThan(backInside, 120)
        assertDoesNotExist(pill, named: "pill after undo (no immediate re-skip)", timeout: 1)
        let playingThrough = waitForPlaybackElapsed(progress, atLeast: backInside + 6, timeout: 15)
        XCTAssertLessThan(
            playingThrough,
            125,
            "Playback should continue inside the disarmed pod instead of re-skipping."
        )
        attachSmokeScreenshot(named: "auto_skip_bug_episode_pill_undo_playthrough")
    }

    @MainActor
    func testSeededNowPlayingArtworkSlideDragDoesNotDismissOrMoveCard() throws {
        let app = makeSeededApp()
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        let initialFrame = overlay.frame

        revealNowPlayingSoundLab(in: app)

        assertNowPlayingOverlay(in: app)
        assertExists(nowPlayingSoundLabPanel(in: app), named: "Now Playing Sound Lab panel")
        XCTAssertEqual(overlay.frame.minY, initialFrame.minY, accuracy: 6)
        XCTAssertEqual(overlay.frame.height, initialFrame.height, accuracy: 6)
    }

    @MainActor
    func testSeededCompactSmokeScreenshots() throws {
        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionRow(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast")

        libraryPodcast.tap()
        assertExists(app.staticTexts["Episodes"], named: "podcast detail episodes section")
        assertExists(seededEpisodeRow(in: app), named: "podcast detail seeded episode")
        attachSmokeScreenshot(named: "podcast_detail")
        // The rewritten podcast detail fills the default scan band with its
        // dark hero header, so measure the plate in the episode card's own
        // vertical band instead.
        let episodeRowFrame = seededEpisodeRow(in: app).frame
        let appHeight = app.windows.firstMatch.frame.height
        assertCompactCardPlateIsInset(
            named: "podcast detail compact card plate",
            verticalBand: (
                start: episodeRowFrame.minY / appHeight,
                end: episodeRowFrame.maxY / appHeight
            )
        )

        tapBackButton(in: app)
        assertExists(libraryPodcast, named: "Library root after podcast detail")

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        openCurrentEpisodeDetailFromNowPlaying(in: app)
        assertExists(episodePlaybackControl(in: app), named: "episode playback control")
        assertExists(app.staticTexts["Show Notes"], named: "episode show notes heading")
        attachSmokeScreenshot(named: "episode_detail")

        app.buttons["Open Now Playing"].tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5) || app.buttons["Play"].exists)
        assertPlayerUtilityControlsExist(in: app)

        dismissNowPlayingOverlay(in: app)
        tapBackButton(in: app)
        openInbox(in: app)
        let inboxEpisodeAfterPlayback = seededEpisodeRow(in: app)
        assertExists(inboxEpisodeAfterPlayback, named: "Inbox root after playback")
        assertMiniPlayerDoesNotCover(inboxEpisodeAfterPlayback, named: "seeded inbox episode", in: app)
        attachSmokeScreenshot(named: "inbox_compact")
        assertCompactCardPlateIsInset(named: "Inbox compact card plate")

        openLibrary(in: app)
        assertExists(libraryPodcast, named: "seeded library podcast with mini-player")
        assertMiniPlayerDoesNotCover(libraryPodcast, named: "seeded library podcast", in: app)
        attachSmokeScreenshot(named: "library_compact")
        assertCompactCardPlateIsInset(named: "Library compact card plate")

        app.buttons["Open Now Playing"].tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        assertPlayerUtilityControlsExist(in: app)
        attachSmokeScreenshot(named: "now_playing_expanded")

        dismissNowPlayingOverlay(in: app)
        assertExists(libraryPodcast, named: "Library after dismissing Now Playing")
        assertMiniPlayerDoesNotCover(libraryPodcast, named: "seeded library podcast after dismiss", in: app)
        attachSmokeScreenshot(named: "library_compact_after_dismiss")

        openSettings(in: app)
        assertExists(app.staticTexts["iCloud Sync"], named: "iCloud Sync section")
        assertExists(syncStatusTitle(in: app), named: "iCloud sync status")
        let downloadedEpisodesRow = app.staticTexts["Downloaded Episodes"]
        scrollUntilExists(downloadedEpisodesRow, in: app)
        assertExists(app.staticTexts["Local Storage"], named: "Local Storage section")
        assertExists(app.staticTexts["Feed Cache"], named: "Feed Cache row")
        assertExists(app.staticTexts["Artwork Cache"], named: "Artwork Cache row")
        assertExists(downloadedEpisodesRow, named: "Downloaded Episodes row")
        attachSmokeScreenshot(named: "settings_sync")

        let diagnosticsLink = app.buttons["Diagnostics"]
        scrollUntilHittable(diagnosticsLink, in: app)
        scrollUntilMiniPlayerDoesNotCover(diagnosticsLink, in: app)
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
        openCurrentEpisodeDetailFromNowPlaying(in: app)
        assertExists(episodePlaybackControl(in: app), named: "episode playback control")
        let downloadedButton = app.buttons["Downloaded"]
        assertExists(downloadedButton, named: "Downloaded button")
        assertExists(elementContaining(label: "Downloaded", in: app), named: "downloaded metadata chip")
        attachSmokeScreenshot(named: "episode_detail_completed_download")

        downloadedButton.tap()
        assertExists(app.buttons["Delete Download"], named: "Delete Download menu action")
        attachSmokeScreenshot(named: "episode_detail_downloaded_menu")
        dismissContextualMenu(in: app)

        app.tabBars.buttons["Settings"].tap()
        let deleteAllDownloadsButton = app.buttons["Delete All Downloads"]
        scrollUntilHittable(deleteAllDownloadsButton, in: app)
        assertExists(app.staticTexts["Downloaded Episodes"], named: "Downloaded Episodes row")
        assertExists(deleteAllDownloadsButton, named: "Delete All Downloads button")
        attachSmokeScreenshot(named: "settings_downloads")
    }

    @MainActor
    func testSeededDownloadsTabLocalPlaybackAndEditSelection() throws {
        let app = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsCompletedDownload: true
        )
        app.launch()

        let downloadsTab = app.tabBars.buttons["Downloads"]
        assertHittable(downloadsTab, named: "Downloads tab")
        downloadsTab.tap()

        assertExists(app.navigationBars["Downloads"], named: "Downloads navigation bar")
        assertExists(app.staticTexts["Downloaded Episodes"], named: "Downloads storage summary")
        assertExists(app.staticTexts["Downloaded"], named: "Downloaded section")

        let byPodcast = app.buttons["By Podcast"]
        assertHittable(byPodcast, named: "By Podcast disclosure")
        byPodcast.tap()
        assertExists(
            app.descendants(matching: .any)["download-podcast-https://example.com/ui-test-feed.xml"],
            named: "downloaded podcast breakdown"
        )

        let downloadedRowButton = app.buttons.matching(identifier: Self.seededEpisodeRowIdentifier).firstMatch
        scrollUntilHittable(downloadedRowButton, in: app)
        assertHittable(downloadedRowButton, named: "downloaded episode playback row")
        downloadedRowButton.tap()

        assertNowPlayingOverlay(in: app)
        XCTAssertFalse(app.alerts["Playback Failed"].waitForExistence(timeout: 2))
        dismissNowPlayingOverlay(in: app)

        let miniPlayer = app.buttons["Open Now Playing"]
        assertExists(miniPlayer, named: "mini-player after local playback")

        let editButton = app.navigationBars["Downloads"].buttons["Edit"]
        assertHittable(editButton, named: "Downloads Edit button")
        editButton.tap()

        assertDoesNotExist(
            app.descendants(matching: .any)
                .matching(identifier: Self.seededEpisodeRowIdentifier)
                .firstMatch,
            named: "download playback row while editing",
            timeout: 5
        )
        let selectionRow = app.descendants(matching: .any)
            .matching(identifier: Self.seededDownloadSelectionRowIdentifier)
            .firstMatch
        scrollUntilHittable(selectionRow, in: app)
        assertHittable(selectionRow, named: "download selection row")
        selectionRow.tap()

        assertExists(miniPlayer, named: "mini-player after selecting a download")

        let deleteSelected = app.buttons["Delete Selected (1)"]
        assertMiniPlayerDoesNotCover(
            deleteSelected,
            named: "Delete Selected edit action",
            in: app
        )
        attachSmokeScreenshot(named: "downloads_edit_selection_with_mini_player")

        deleteSelected.tap()
        let confirmDeleteSelected = app.buttons["Delete Selected"]
        assertHittable(confirmDeleteSelected, named: "Delete Selected confirmation")
        confirmDeleteSelected.tap()

        assertExists(app.staticTexts["No Downloads"], named: "Downloads empty state after bulk deletion")
        assertDoesNotExist(
            app.navigationBars["Downloads"].buttons["Done"],
            named: "Done button after deleting the final completed download",
            timeout: 5
        )
    }

    @MainActor
    func testSeededTranscriptAndSpeechModelSmoke() throws {
        let app = makeSeededApp(
            seedsCompletedDownload: true,
            seedsTranscriptionModel: true,
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true
        )
        app.launch()

        openSettings(in: app)
        scrollUntilExists(app.staticTexts["Transcription"], in: app)
        assertExists(app.staticTexts["Transcription"], named: "Transcription settings section")
        // The Fast/Accurate model picker left the product path;
        // whisper management in main Settings is tiny-pinned.
        XCTAssertFalse(app.buttons["Fast"].exists, "Fast/Accurate picker must be out of the product path")
        XCTAssertFalse(app.buttons["Accurate"].exists, "Fast/Accurate picker must be out of the product path")
        let installedStatus = elementContaining(label: "Installed", in: app)
        scrollUntilExists(installedStatus, in: app)
        assertExists(installedStatus, named: "installed speech model status")

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()
        assertNowPlayingOverlay(in: app)

        let moreMenuButton = app.buttons["More Actions"]
        assertExists(moreMenuButton, named: "now playing more actions menu")
        moreMenuButton.tap()
        let showTranscriptItem = app.buttons["Show Transcript"]
        assertExists(showTranscriptItem, named: "Show Transcript action")
        showTranscriptItem.tap()
        assertExists(app.staticTexts["Transcript"], named: "transcript sheet title")
        assertExists(app.buttons["Welcome to a deterministic transcript."], named: "transcript sheet line")
        attachSmokeScreenshot(named: "now_playing_transcript_sheet")
        dismissTranscriptSheetAndWaitForNowPlaying(in: app)

        openCurrentEpisodeDetailFromNowPlaying(in: app)

        let readTranscriptButton = app.buttons["Read Transcript"]
        scrollUntilHittable(readTranscriptButton, in: app)
        assertExists(readTranscriptButton, named: "Read Transcript button")
        attachSmokeScreenshot(named: "episode_detail_transcript_entry")
        readTranscriptButton.tap()

        assertExists(app.staticTexts["Transcript"], named: "Transcript route title")
        assertExists(app.buttons["Welcome to a deterministic transcript."], named: "seeded transcript line")
        let annotatedSponsorRow = app.buttons.matching(NSPredicate(
            format: "label == %@ AND value CONTAINS %@",
            "This row is brought to you by Seed Sponsor.",
            "Sponsor segment, Seed Sponsor"
        )).firstMatch
        assertExists(annotatedSponsorRow, named: "seeded sponsor transcript line with promo/ad span")
        attachSmokeScreenshot(named: "episode_transcript_seeded")

        app.buttons["Search Transcript"].tap()
        let searchField = app.textFields["Search Transcript"]
        assertExists(searchField, named: "transcript search field")
        searchField.tap()
        searchField.typeText("deterministic")
        assertExists(app.staticTexts["1 of 1"], named: "transcript search match count")
        attachSmokeScreenshot(named: "episode_transcript_search")
        app.buttons["Close Search"].tap()
        assertDoesNotExist(searchField, named: "transcript search field after close", timeout: 2)

        openTranscriptOptionsMenu(in: app)
        assertDoesNotExist(app.buttons["Analyze Promos & Ads"], named: "Analyze action without ad-analysis token", timeout: 1)
        assertDoesNotExist(app.buttons["Reanalyze Promos & Ads"], named: "Reanalyze action without ad-analysis token", timeout: 1)
        assertDoesNotExist(app.buttons["Retry Promo/Ad Analysis"], named: "Retry action without ad-analysis token", timeout: 1)
        assertExists(app.buttons["Delete Promo/Ad Analysis"], named: "Delete saved promo/ad analysis")
        dismissTranscriptOptionsMenu(in: app)
    }

    @MainActor
    func testSeededNowPlayingMoreMenuOpensTranscriptSheet() throws {
        let app = makeSeededApp(
            seedsTranscriptionModel: true,
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true
        )
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()
        assertNowPlayingOverlay(in: app)

        let moreMenuButton = app.buttons["More Actions"]
        assertExists(moreMenuButton, named: "now playing more actions menu")
        moreMenuButton.tap()
        let showTranscriptItem = app.buttons["Show Transcript"]
        assertExists(showTranscriptItem, named: "Show Transcript action")
        showTranscriptItem.tap()

        assertExists(app.staticTexts["Transcript"], named: "transcript sheet title")
        assertExists(app.buttons["Welcome to a deterministic transcript."], named: "transcript sheet line")
        attachSmokeScreenshot(named: "now_playing_transcript_sheet_standalone")
        dismissTranscriptSheetAndWaitForNowPlaying(in: app)
    }

    @MainActor
    func testOnDemandTranscriptRequestToastOpensEpisodeDescription() throws {
        let app = makeSeededApp(
            seedsCompletedDownload: true,
            completesTranscriptRequests: true
        )
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()
        assertNowPlayingOverlay(in: app)

        app.buttons["More Actions"].tap()
        let generateTranscript = app.buttons["Generate Transcript"]
        assertHittable(generateTranscript, named: "Generate Transcript action")
        generateTranscript.tap()

        let toast = app.descendants(matching: .any)["Transcription Progress Toast"]
        assertExists(toast, named: "transcription request toast")
        let openEpisodeButton = toast.buttons["Open Episode Description from Local Toast"]
        assertHittable(openEpisodeButton, named: "local toast episode description action", timeout: 10)
        assertHittable(toast.buttons["Dismiss"], named: "separate transcript toast dismiss action")
        openEpisodeButton.tap()

        assertDoesNotExist(nowPlayingOverlay(in: app), named: "Now Playing overlay after toast navigation")
        assertExists(
            episodePlaybackControl(in: app),
            named: "episode description after tapping completed local toast",
            timeout: 10
        )
        assertExists(
            app.buttons["Read Transcript"],
            named: "completed transcript status on episode detail",
            timeout: 10
        )

        let miniPlayer = app.buttons["Open Now Playing"]
        assertHittable(miniPlayer, named: "mini-player after local toast navigation")
        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
        assertDoesNotExist(
            app.descendants(matching: .any)["Transcription Progress Toast"],
            named: "consumed local toast after reopening Now Playing"
        )
    }

    @MainActor
    func testOptInLiveWorkerAdAnalysisTranscriptScreenshot() throws {
        let transcriptPath = try requireArtifactPath(
            environmentKey: Self.liveAdAnalysisTranscriptPathEnvironmentKey
        )
        let responsePath = try requireArtifactPath(
            environmentKey: Self.liveAdAnalysisResponsePathEnvironmentKey
        )
        let app = makeSeededApp(seedsTranscriptionModel: true)
        app.launchEnvironment[Self.liveAdAnalysisTranscriptPathEnvironmentKey] = transcriptPath
        app.launchEnvironment[Self.liveAdAnalysisResponsePathEnvironmentKey] = responsePath
        app.launch()

        openInbox(in: app)
        let liveEpisode = liveAdAnalysisEpisodeRow(in: app)
        scrollUntilExists(liveEpisode, in: app, maxSwipes: 3)
        openEpisodeDetailFromContextMenu(
            liveEpisode,
            in: app,
            named: "live Worker ad-analysis episode"
        )

        let viewTranscriptButton = app.buttons["Read Transcript"]
        scrollUntilHittable(viewTranscriptButton, in: app)
        viewTranscriptButton.tap()

        assertExists(app.staticTexts["Transcript"], named: "Transcript route title")
        openTranscriptOptionsMenu(in: app)
        assertDoesNotExist(app.buttons["Analyze Promos & Ads"], named: "Analyze action without ad-analysis token", timeout: 1)
        assertDoesNotExist(app.buttons["Reanalyze Promos & Ads"], named: "Reanalyze action without ad-analysis token", timeout: 1)
        assertExists(app.buttons["Delete Promo/Ad Analysis"], named: "Delete saved live Worker promo/ad analysis")
        dismissTranscriptOptionsMenu(in: app)

        let cancerResearchRow = app.buttons.matching(NSPredicate(
            format: "label == %@ AND value CONTAINS %@",
            "This episode is brought to you by Cancer Research UK.",
            "Sponsor segment"
        )).firstMatch
        scrollUntilVisible(cancerResearchRow, in: app, maxSwipes: 12)
        assertExists(cancerResearchRow, named: "live Worker transcript ad row with promo/ad span")
        attachSmokeScreenshot(named: "episode_transcript_live_worker_ad_analysis")
    }

    @MainActor
    func testOptInDebugBearerAdAnalysisRoundTripsAgainstDevWorker() throws {
        let clientToken = try requireEnvironmentValue(
            Self.adAnalysisClientTokenEnvironmentKey,
            skipMessage: "Set \(Self.adAnalysisClientTokenEnvironmentKey) to run the live dev Worker ad-analysis Debug bearer smoke."
        )
        let app = makeSeededApp(
            seedsTranscriptionModel: true,
            seedsCompletedTranscript: true
        )
        app.launchEnvironment[Self.adAnalysisClientTokenEnvironmentKey] = clientToken
        if let baseURL = optionalEnvironmentValue(Self.adAnalysisBaseURLEnvironmentKey) {
            app.launchEnvironment[Self.adAnalysisBaseURLEnvironmentKey] = baseURL
        }
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()
        assertNowPlayingOverlay(in: app)
        openCurrentEpisodeDetailFromNowPlaying(in: app)

        let viewTranscriptButton = app.buttons["Read Transcript"]
        scrollUntilHittable(viewTranscriptButton, in: app)
        viewTranscriptButton.tap()

        assertExists(app.staticTexts["Transcript"], named: "Transcript route title")
        assertExists(app.buttons["This row is brought to you by Seed Sponsor."], named: "seeded sponsor transcript line")
        openTranscriptOptionsMenu(in: app)
        let analyzeButton = app.buttons["Analyze Promos & Ads"]
        assertExists(analyzeButton, named: "Analyze Promos & Ads menu action")
        analyzeButton.tap()

        assertExists(app.staticTexts["Analyzing Promos & Ads"], named: "live dev Worker analysis progress", timeout: 10)
        XCTAssertTrue(
            app.staticTexts["Analyzing Promos & Ads"].waitForNonExistence(timeout: 120),
            "Live dev Worker analysis should finish within two minutes."
        )
        openTranscriptOptionsMenu(in: app)
        assertDoesNotExist(app.buttons["Retry Promo/Ad Analysis"], named: "Retry action after successful analysis", timeout: 1)
        assertExists(app.buttons["Delete Promo/Ad Analysis"], named: "Delete live dev Worker promo/ad analysis")
        dismissTranscriptOptionsMenu(in: app)
        attachSmokeScreenshot(named: "episode_transcript_live_dev_worker_ad_analysis")
    }

    @MainActor
    func testOptInPhysicalAppAttestAdAnalysisRoundTripsAgainstDevWorker() throws {
        #if !OPENCAST_RUN_PHYSICAL_APP_ATTEST_AD_ANALYSIS_UI_TESTS
        let shouldRunProbe =
            ProcessInfo.processInfo.environment[Self.physicalAppAttestAdAnalysisProbeEnvironmentKey] == "1"
            || FileManager.default.fileExists(atPath: Self.physicalAppAttestAdAnalysisProbeFilePath)
        guard shouldRunProbe else {
            throw XCTSkip("Set \(Self.physicalAppAttestAdAnalysisProbeEnvironmentKey)=1, create \(Self.physicalAppAttestAdAnalysisProbeFilePath), or build with -DOPENCAST_RUN_PHYSICAL_APP_ATTEST_AD_ANALYSIS_UI_TESTS to run the physical-device App Attest ad-analysis smoke.")
        }
        #endif

        let app = makeSeededApp(
            seedsTranscriptionModel: true,
            seedsCompletedTranscript: true
        )
        app.launchEnvironment[Self.adAnalysisClientTokenEnvironmentKey] = ""
        app.launchEnvironment["OPENCAST_RESET_AD_ANALYSIS_APP_ATTEST_CREDENTIAL"] = "1"
        if let baseURL = optionalEnvironmentValue(Self.adAnalysisBaseURLEnvironmentKey) {
            app.launchEnvironment[Self.adAnalysisBaseURLEnvironmentKey] = baseURL
        }
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()
        assertNowPlayingOverlay(in: app)
        openCurrentEpisodeDetailFromNowPlaying(in: app)

        let viewTranscriptButton = app.buttons["Read Transcript"]
        scrollUntilHittable(viewTranscriptButton, in: app)
        viewTranscriptButton.tap()

        assertExists(app.staticTexts["Transcript"], named: "Transcript route title")
        assertExists(app.buttons["This row is brought to you by Seed Sponsor."], named: "seeded sponsor transcript line")
        openTranscriptOptionsMenu(in: app)
        let analyzeButton = app.buttons["Analyze Promos & Ads"]
        assertExists(analyzeButton, named: "Analyze Promos & Ads menu action")
        analyzeButton.tap()

        assertExists(app.staticTexts["Analyzing Promos & Ads"], named: "physical App Attest analysis progress", timeout: 10)
        XCTAssertTrue(
            app.staticTexts["Analyzing Promos & Ads"].waitForNonExistence(timeout: 120),
            "Physical App Attest analysis should finish within two minutes."
        )
        openTranscriptOptionsMenu(in: app)
        let firstDeleteButton = app.buttons["Delete Promo/Ad Analysis"]
        assertExists(firstDeleteButton, named: "Delete physical App Attest promo/ad analysis")
        dismissTranscriptOptionsMenu(in: app)
        attachSmokeScreenshot(named: "episode_transcript_physical_app_attest_dev_worker_ad_analysis")

        openTranscriptOptionsMenu(in: app)
        firstDeleteButton.tap()
        openTranscriptOptionsMenu(in: app)
        let cachedKeyAnalyzeButton = app.buttons["Analyze Promos & Ads"]
        assertExists(cachedKeyAnalyzeButton, named: "Analyze action after deleting first analysis")
        cachedKeyAnalyzeButton.tap()

        _ = app.staticTexts["Analyzing Promos & Ads"].waitForExistence(timeout: 2)
        XCTAssertTrue(
            app.staticTexts["Analyzing Promos & Ads"].waitForNonExistence(timeout: 120),
            "Cached-key analysis should finish within two minutes."
        )
        openTranscriptOptionsMenu(in: app)
        assertExists(app.buttons["Delete Promo/Ad Analysis"], named: "Delete physical App Attest cached-key ad analysis")
        dismissTranscriptOptionsMenu(in: app)
        attachSmokeScreenshot(named: "episode_transcript_physical_app_attest_dev_worker_ad_analysis_cached_key")
    }

    @MainActor
    func testSeededStaleAdAnalysisDoesNotAnnotateTranscriptRows() throws {
        let app = makeSeededApp(
            seedsCompletedDownload: true,
            seedsTranscriptionModel: true,
            seedsCompletedTranscript: true,
            seedsStaleAdAnalysis: true
        )
        app.launchEnvironment[Self.adAnalysisClientTokenEnvironmentKey] = ""
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()
        assertNowPlayingOverlay(in: app)
        openCurrentEpisodeDetailFromNowPlaying(in: app)

        let viewTranscriptButton = app.buttons["Read Transcript"]
        scrollUntilHittable(viewTranscriptButton, in: app)
        viewTranscriptButton.tap()

        assertExists(app.staticTexts["Transcript"], named: "Transcript route title")
        assertExists(app.staticTexts["Outdated — run again"], named: "stale promo/ad analysis banner")
        let sponsorRow = app.buttons["This row is brought to you by Seed Sponsor."]
        assertExists(sponsorRow, named: "seeded sponsor transcript line")
        XCTAssertFalse(
            ((sponsorRow.value as? String) ?? "").contains("Sponsor segment"),
            "A stale analysis must not annotate transcript rows"
        )
        attachSmokeScreenshot(named: "episode_transcript_stale_ad_analysis_no_badges")

        openTranscriptOptionsMenu(in: app)
        assertDoesNotExist(app.buttons["Analyze Promos & Ads"], named: "Analyze action without ad-analysis token", timeout: 1)
        assertDoesNotExist(app.buttons["Reanalyze Promos & Ads"], named: "Reanalyze action without ad-analysis token", timeout: 1)
        let deleteAnalysisButton = app.buttons["Delete Promo/Ad Analysis"]
        assertExists(deleteAnalysisButton, named: "Delete stale promo/ad analysis")

        deleteAnalysisButton.tap()

        // Backstop-only budget: the wait returns the moment the banner
        // clears, but the delete's save→reload propagation can exceed 5s
        // under full-suite clone load (observed once during closeout
        // lane; green in isolation).
        XCTAssertTrue(
            app.staticTexts["Outdated — run again"].waitForNonExistence(timeout: 15),
            "The stale banner should clear after deleting the analysis."
        )
        openTranscriptOptionsMenu(in: app)
        let unavailableAnalyzeItem = app.buttons["Analyze Promos & Ads"]
        assertExists(unavailableAnalyzeItem, named: "Analyze action after deleting stale analysis")
        XCTAssertFalse(
            unavailableAnalyzeItem.isEnabled,
            "Analyze must stay disabled without App Attest support"
        )
        assertDoesNotExist(app.buttons["Delete Promo/Ad Analysis"], named: "Delete action after deleting stale analysis", timeout: 1)
        dismissTranscriptOptionsMenu(in: app)
        assertExists(app.buttons["This row is brought to you by Seed Sponsor."], named: "transcript line after deleting stale promo/ad analysis")
    }

    @MainActor
    func testSeededTranscriptWithoutAdAnalysisTokenHidesAnalyzeControls() throws {
        let app = makeSeededApp(
            seedsCompletedDownload: true,
            seedsTranscriptionModel: true,
            seedsCompletedTranscript: true
        )
        app.launchEnvironment[Self.adAnalysisClientTokenEnvironmentKey] = ""
        app.launch()

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()
        assertNowPlayingOverlay(in: app)
        openCurrentEpisodeDetailFromNowPlaying(in: app)

        let viewTranscriptButton = app.buttons["Read Transcript"]
        scrollUntilHittable(viewTranscriptButton, in: app)
        viewTranscriptButton.tap()

        assertExists(app.staticTexts["Transcript"], named: "Transcript route title")
        openTranscriptOptionsMenu(in: app)
        let analyzeItem = app.buttons["Analyze Promos & Ads"]
        assertExists(analyzeItem, named: "Analyze action in transcript menu")
        XCTAssertFalse(
            analyzeItem.isEnabled,
            "Analyze must be disabled without an ad-analysis token"
        )
        assertDoesNotExist(app.buttons["Reanalyze Promos & Ads"], named: "Reanalyze action without ad-analysis token", timeout: 1)
        dismissTranscriptOptionsMenu(in: app)
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
    func testSeededEpisodeDetailRedesignScreenshotMatrix() throws {
        let darkApp = makeSeededApp(
            seedsCompletedDownload: true,
            seedsTranscriptionModel: true,
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true
        )
        darkApp.launch()
        openSeededEpisodeDetail(in: darkApp)
        assertExists(episodePlaybackControl(in: darkApp), named: "episode playback control")
        assertExists(darkApp.buttons["Downloaded"], named: "Downloaded action button")
        assertExists(
            elementContaining(label: "ad segment", in: darkApp),
            named: "ad-span timeline caption"
        )
        assertExists(darkApp.buttons["Read Transcript"], named: "transcript entry card")
        attachSmokeScreenshot(named: "episode_detail_full_pipeline_dark")

        let scrollStart = darkApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let scrollEnd = darkApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        scrollStart.press(forDuration: 0.05, thenDragTo: scrollEnd)
        assertExists(darkApp.staticTexts["Show Notes"], named: "show notes heading after scroll")
        attachSmokeScreenshot(named: "episode_detail_show_notes_dark")
        darkApp.terminate()

        let lightApp = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsCompletedDownload: true,
            seedsTranscriptionModel: true,
            seedsCompletedTranscript: true,
            seedsCompletedAdAnalysis: true
        )
        lightApp.launch()
        openSeededEpisodeDetail(in: lightApp)
        assertExists(episodePlaybackControl(in: lightApp), named: "episode playback control (light)")
        attachSmokeScreenshot(named: "episode_detail_full_pipeline_light")
        lightApp.terminate()

        let longNotesApp = makeSeededApp(
            forcesDarkMode: false,
            forcesLightMode: true,
            seedsEpisodeProgress: true,
            seedsLongShowNotes: true
        )
        longNotesApp.launch()
        openSeededEpisodeDetail(in: longNotesApp)
        assertExists(episodePlaybackControl(in: longNotesApp), named: "episode playback control (long notes)")
        for _ in 0..<4 {
            let start = longNotesApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = longNotesApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        attachSmokeScreenshot(named: "episode_detail_long_show_notes_bottom_light")
    }

    @MainActor
    func testEpisodeDetailSupportsAccessibilityDynamicType() throws {
        let app = makeSeededApp(
            preferredContentSizeCategoryName: "UICTContentSizeCategoryAccessibilityXXXL"
        )
        app.launch()
        openSeededEpisodeDetail(in: app)

        assertExists(episodePlaybackControl(in: app), named: "episode playback control at AX size")
        assertExists(app.buttons["Download"], named: "Download button at AX size")
        assertExists(app.buttons["Make Ad-Free"], named: "Make Ad-Free button at AX size")
        let showLink = app.buttons["UI Test Show"]
        assertHittable(showLink, named: "episode show link at AX size")
        XCTAssertGreaterThanOrEqual(showLink.frame.width, 44)
        XCTAssertGreaterThanOrEqual(showLink.frame.height, 44)
        attachSmokeScreenshot(named: "episode_detail_dynamic_type_ax")
        showLink.tap()
        assertExists(
            app.descendants(matching: .any)["Podcast Hero Header"],
            named: "show detail from AX-sized episode link"
        )
    }

    @MainActor
    func testSeededFailedDownloadShowsPipelineCardRetry() throws {
        let app = makeSeededApp(seedsFailedDownload: true)
        app.launch()
        openSeededEpisodeDetail(in: app)

        assertExists(app.staticTexts["Download didn't finish"], named: "failed download pipeline card title")
        assertExists(
            elementContaining(label: "The download couldn't finish.", in: app),
            named: "failed download friendly message"
        )
        assertExists(app.buttons["Retry"], named: "pipeline card Retry action")
        attachSmokeScreenshot(named: "episode_detail_failed_download")
    }

    @MainActor
    func testRemoteTranscriptionFailureFixtureShowsTerminalStateAndFallback() throws {
        let app = makeSeededApp(seedsCompletedDownload: true)
        app.launchArguments += [
            "-OPENCAST_REMOTE_TRANSCRIPTION_DEV",
            "-OPENCAST_REMOTE_TRANSCRIPTION_FIXTURE", "failure:ui-test-episode-1"
        ]
        app.launch()
        openSeededEpisodeDetail(in: app)

        assertExists(
            app.staticTexts["Remote transcription didn't finish"],
            named: "remote failure card title"
        )
        assertExists(
            elementContaining(label: "The server couldn't transcribe this episode.", in: app),
            named: "category-level failure copy"
        )
        let fallback = app.buttons["Transcribe on Device"]
        assertExists(fallback, named: "local fallback action")
        attachSmokeScreenshot(named: "episode_detail_remote_failure")

        // The fallback hands off to the existing local transcription path and
        // dismisses the failure surface.
        fallback.tap()
        assertDoesNotExist(
            app.staticTexts["Remote transcription didn't finish"],
            named: "remote failure card after fallback",
            timeout: 5
        )
    }

    @MainActor
    func testRemoteTranscriptionProgressFixtureShowsETAAndDeterminateProgress() throws {
        let app = makeSeededApp(seedsCompletedDownload: true)
        app.launchArguments += [
            "-OPENCAST_REMOTE_TRANSCRIPTION_DEV",
            "-OPENCAST_REMOTE_TRANSCRIPTION_FIXTURE", "transcribing:ui-test-episode-1"
        ]
        app.launch()
        openSeededNowPlaying(in: app)

        let toast = app.descendants(matching: .any)["Remote Transcription Progress Toast"]
        assertExists(toast, named: "Now Playing remote transcription toast")
        assertExists(toast.staticTexts["Transcribing"], named: "Now Playing remote stage")
        assertExists(
            toast.staticTexts["About 1 minute remaining."],
            named: "Now Playing remote ETA"
        )
        let toastProgress = toast.progressIndicators["Remote Transcription Chunk Progress"]
        assertExists(toastProgress, named: "Now Playing determinate remote progress")
        XCTAssertEqual(toastProgress.label, "Transcription progress")
        XCTAssertEqual(toastProgress.value as? String, "43 percent")
        let openEpisodeButton = toast.buttons["Open Episode Description from Remote Toast"]
        assertHittable(openEpisodeButton, named: "remote toast episode description action")
        assertHittable(toast.buttons["Cancel"], named: "separate remote toast cancel action")

        openEpisodeButton.tap()
        assertDoesNotExist(nowPlayingOverlay(in: app), named: "Now Playing overlay after remote toast navigation")
        let card = app.descendants(matching: .any)["Remote Transcription Status Card"]
        assertExists(card, named: "episode remote transcription status card")
        assertExists(card.staticTexts["Transcribing"], named: "episode remote stage")
        assertExists(
            card.staticTexts["About 1 minute remaining."],
            named: "episode remote ETA"
        )
        let cardProgress = card.progressIndicators["Remote Transcription Chunk Progress"]
        assertExists(cardProgress, named: "episode determinate remote progress")
        XCTAssertEqual(cardProgress.label, "Transcription progress")
        XCTAssertEqual(cardProgress.value as? String, "43 percent")
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
        assertExists(
            episodePlaybackControl(in: progressApp),
            named: "episode playback control after Clear Progress"
        )

        let markPlayedApp = makeSeededApp()
        markPlayedApp.launch()
        openSeededEpisodeDetail(in: markPlayedApp)

        markPlayedApp.buttons["Episode Actions"].tap()
        let markPlayedButton = markPlayedApp.buttons["Mark Played"]
        assertExists(markPlayedButton, named: "Mark Played action")
        markPlayedButton.tap()
        assertExists(
            elementContaining(label: "Played", in: markPlayedApp),
            named: "Played chip after Mark Played",
            timeout: 10
        )
    }

    @MainActor
    func testNowPlayingVoiceBoostCanToggleWithScreenshots() throws {
        let app = makeSeededApp(seedsPerEpisodeVoiceBoost: true)
        app.launch()

        openSeededNowPlayingSoundLab(in: app)

        let voiceBoostToggle = app.switches["Voice Boost"]
        assertExists(voiceBoostToggle, named: "Voice Boost Sound Lab toggle")
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
            preferredContentSizeCategoryName: "UICTContentSizeCategoryAccessibilityXXXL"
        )
        app.launch()

        openSeededNowPlayingSoundLab(in: app)

        let panel = nowPlayingSoundLabPanel(in: app)
        let voiceBoostToggle = app.switches["Voice Boost"]
        let adAction = app.buttons.matching(identifier: "Skip Promos & Ads").firstMatch
        let transcriptAction = app.buttons.matching(
            identifier: Self.soundLabTranscriptActionIdentifier
        ).firstMatch
        let header = app.staticTexts["Sound Lab"].firstMatch
        assertToggle(voiceBoostToggle, isOn: true)
        assertExists(adAction, named: "Skip Promos & Ads at Accessibility XXXL")
        assertExists(transcriptAction, named: "transcript action at Accessibility XXXL")

        let controls = [voiceBoostToggle, adAction, transcriptAction]
        for control in controls {
            XCTAssertTrue(control.isHittable, "\(control.label) should remain hittable")
            XCTAssertGreaterThanOrEqual(control.frame.height, 43.99)
            XCTAssertTrue(
                panel.frame.contains(control.frame),
                "\(control.label) should remain fully inside the Sound Lab panel"
            )
            if header.exists {
                XCTAssertFalse(
                    control.frame.intersects(header.frame),
                    "\(control.label) should not overlap the Sound Lab header"
                )
            }
        }
        for firstIndex in controls.indices {
            for secondIndex in controls.indices where secondIndex > firstIndex {
                XCTAssertFalse(
                    controls[firstIndex].frame.intersects(controls[secondIndex].frame),
                    "Sound Lab controls should not overlap: \(controls[firstIndex].label) "
                        + "\(controls[firstIndex].frame) and \(controls[secondIndex].label) "
                        + "\(controls[secondIndex].frame)"
                )
            }
        }

        attachSmokeScreenshot(named: "now_playing_sound_lab_accessibility_xxxl")

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
    func testOptInRestIsScienceRemoteFeedCanPlayFromAppUI() throws {
        let shouldRunRemoteProbe = ProcessInfo.processInfo.environment["OPENCAST_RUN_REMOTE_VOICEBOOST_UI_TESTS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/opencast-run-remote-voiceboost-ui-tests")
        guard shouldRunRemoteProbe else {
            throw XCTSkip("Set OPENCAST_RUN_REMOTE_VOICEBOOST_UI_TESTS=1 or create /tmp/opencast-run-remote-voiceboost-ui-tests to run the live The Rest Is Science playback probe.")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-dark-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = "https://feeds.megaphone.fm/GLT6907573392"
        app.launchEnvironment["OPENCAST_CAPTURE_VOICEBOOST_DIAGNOSTICS"] = "1"
        app.launch()

        openLibrary(in: app)
        tapAddPodcastButton(in: app)
        app.buttons["Subscribe"].tap()

        assertExists(app.staticTexts["The Rest Is Science - Goalhanger"], named: "The Rest Is Science subscription", timeout: 30)
        openInbox(in: app)

        let firstEpisode = restIsScienceFirstEpisode(in: app)
        assertExists(firstEpisode, named: "The Rest Is Science inbox episode", timeout: 30)
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
    func testOptInThisAmericanLifeFallbackDismissesOnboarding() throws {
        try requireThisAmericanLifeReviewerPathProbe()

        let app = makeOnboardingApp(forcesDarkMode: false)
        app.launch()

        assertExists(app.staticTexts["Welcome to opencast!"], named: "clean onboarding welcome", timeout: 20)
        app.buttons["Continue"].tap()
        assertExists(app.buttons["Skip"], named: "Skip OPML onboarding action")
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Find Podcasts"], named: "Find Podcasts onboarding screen")

        app.buttons["Continue"].tap()
        assertExists(app.staticTexts["Tiny Whisper Model"], named: "Tiny Whisper onboarding screen")
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["New Episode Alerts"], named: "notification onboarding screen")
        app.buttons["Done"].tap()
        let addThisAmericanLife = app.buttons["Add This American Life"]
        assertExists(addThisAmericanLife, named: "This American Life fallback confirmation", timeout: 10)
        addThisAmericanLife.tap()
        XCTAssertTrue(
            app.staticTexts["Find Podcasts"].waitForNonExistence(timeout: 90),
            "Onboarding should dismiss after accepting the This American Life fallback."
        )

        openLibrary(in: app)
        assertExists(app.staticTexts["This American Life"], named: "This American Life library subscription", timeout: 90)
        openInbox(in: app)
        assertExists(
            thisAmericanLifeEpisodeRow(in: app),
            named: "This American Life inbox episode",
            timeout: 90
        )
    }

    @MainActor
    func testOptInThisAmericanLifeCleanReviewerPath() throws {
        try requireThisAmericanLifeReviewerPathProbe()

        let app = makeOnboardingApp(forcesDarkMode: false)
        app.launch()

        assertExists(app.staticTexts["Welcome to opencast!"], named: "clean onboarding welcome", timeout: 20)
        app.buttons["Continue"].tap()
        assertExists(app.buttons["Skip"], named: "Skip OPML onboarding action")
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Find Podcasts"], named: "Find Podcasts onboarding screen")
        assertExists(app.textFields["Podcast or creator"], named: "onboarding podcast search field")
        assertExists(app.buttons["RSS"], named: "onboarding RSS mode")
        assertExists(app.staticTexts["This American Life"], named: "This American Life sample suggestion")

        app.buttons["Continue"].tap()
        assertExists(app.staticTexts["Tiny Whisper Model"], named: "Tiny Whisper onboarding screen")
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["New Episode Alerts"], named: "notification onboarding screen")
        app.buttons["Done"].tap()
        let addThisAmericanLife = app.buttons["Add This American Life"]
        assertExists(addThisAmericanLife, named: "This American Life fallback confirmation", timeout: 10)
        addThisAmericanLife.tap()
        XCTAssertTrue(
            app.staticTexts["Find Podcasts"].waitForNonExistence(timeout: 90),
            "Onboarding should dismiss after accepting the This American Life fallback."
        )

        openLibrary(in: app)
        assertExists(app.staticTexts["This American Life"], named: "This American Life library subscription", timeout: 90)
        openInbox(in: app)
        let inboxEpisode = thisAmericanLifeEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "This American Life inbox episode", timeout: 90)
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control", timeout: 30)
        openCurrentEpisodeDetailFromNowPlaying(in: app)

        assertExists(episodePlaybackControl(in: app), named: "episode playback control", timeout: 20)
        let miniPlayer = app.buttons["Open Now Playing"]
        assertExists(miniPlayer, named: "mini-player from episode detail", timeout: 20)
        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control after reopening player", timeout: 30)

        let pauseButton = nowPlayingOverlay(in: app).buttons["Pause"].firstMatch
        assertExists(pauseButton, named: "Pause button", timeout: 30)
        pauseButton.tap()
        let playButton = nowPlayingOverlay(in: app).buttons["Play"].firstMatch
        assertExists(playButton, named: "Play button after pausing", timeout: 10)
        playButton.tap()
        assertExists(nowPlayingOverlay(in: app).buttons["Pause"].firstMatch, named: "Pause button after resuming", timeout: 30)

        let progress = playbackProgress(in: app)
        let scrubStart = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
        let scrubEnd = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.5))
        scrubStart.press(forDuration: 0.08, thenDragTo: scrubEnd)

        let pauseAfterScrubButton = nowPlayingOverlay(in: app).buttons["Pause"].firstMatch
        if pauseAfterScrubButton.waitForExistence(timeout: 5) {
            pauseAfterScrubButton.tap()
        }
        RunLoop.current.run(until: Date.now.addingTimeInterval(2))

        app.terminate()
        app.launch()

        if !nowPlayingOverlay(in: app).waitForExistence(timeout: 5) {
            let miniPlayer = app.buttons["Open Now Playing"]
            assertExists(miniPlayer, named: "mini-player after relaunch", timeout: 20)
            miniPlayer.tap()
        }
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control after relaunch", timeout: 20)
        dismissNowPlayingOverlay(in: app)

        openSettings(in: app)
        assertExists(app.staticTexts["Settings"], named: "Settings title", timeout: 10)
        scrollUntilExists(app.staticTexts["Import & Export"], in: app, maxSwipes: 4)
        assertExists(app.staticTexts["Import & Export"], named: "OPML Import & Export section", timeout: 10)
        assertExists(app.buttons["Export Subscriptions"], named: "OPML Export Subscriptions action", timeout: 10)
    }

    @MainActor
    func testOptInThisAmericanLifeRapidScrubVisualProbe() throws {
        try requireThisAmericanLifeReviewerPathProbe()

        let app = makeOnboardingApp(forcesDarkMode: false)
        app.launch()

        assertExists(app.staticTexts["Welcome to opencast!"], named: "clean onboarding welcome", timeout: 20)
        app.buttons["Continue"].tap()
        assertExists(app.buttons["Skip"], named: "Skip OPML onboarding action")
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Find Podcasts"], named: "Find Podcasts onboarding screen")

        app.buttons["Continue"].tap()
        assertExists(app.staticTexts["Tiny Whisper Model"], named: "Tiny Whisper onboarding screen")
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["New Episode Alerts"], named: "notification onboarding screen")
        app.buttons["Done"].tap()
        let addThisAmericanLife = app.buttons["Add This American Life"]
        assertExists(addThisAmericanLife, named: "This American Life fallback confirmation", timeout: 10)
        addThisAmericanLife.tap()
        XCTAssertTrue(
            app.staticTexts["Find Podcasts"].waitForNonExistence(timeout: 90),
            "Onboarding should dismiss after accepting the This American Life fallback."
        )

        openInbox(in: app)
        let inboxEpisode = thisAmericanLifeEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "This American Life inbox episode", timeout: 90)
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        let progress = playbackProgress(in: app)
        assertExists(progress, named: "Playback Progress control", timeout: 30)

        RunLoop.current.run(until: Date.now.addingTimeInterval(3))

        let initialValue = progress.value as? String
        let offsets: [(CGFloat, CGFloat)] = [
            (0.03, 0.84),
            (0.84, 0.16),
            (0.16, 0.80),
            (0.80, 0.24),
            (0.24, 0.72)
        ]
        for (start, end) in offsets {
            let startCoordinate = progress.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
            let endCoordinate = progress.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5))
            startCoordinate.press(forDuration: 0.12, thenDragTo: endCoordinate)
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.35))
        }

        let scrubbed = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String else {
                return false
            }

            return value != initialValue && !value.hasPrefix("0:00 elapsed")
        }
        let expectation = XCTNSPredicateExpectation(predicate: scrubbed, object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed)

        RunLoop.current.run(until: Date.now.addingTimeInterval(4))
        attachSmokeScreenshot(named: "tal_rapid_scrub_visual_probe")
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

        openInbox(in: app)

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        assertPlayerUtilityControlsExist(in: app)
        assertPlayerUtilityControlHeightsAreBalanced(in: app)
        attachSmokeScreenshot(named: "now_playing_expanded_light")

        let pauseButton = nowPlayingOverlay(in: app).buttons["Pause"].firstMatch
        if pauseButton.waitForExistence(timeout: 5) {
            pauseButton.tap()
        }
        assertExists(nowPlayingOverlay(in: app).buttons["Play"].firstMatch, named: "Play button after pausing")
        attachSmokeScreenshot(named: "now_playing_expanded_light_paused")
    }

    @MainActor
    func testSeededUpNextQueueSmoke() throws {
        let app = makeSeededApp(seedsUpNextQueue: true)
        app.launch()

        openSeededNowPlaying(in: app)
        let upNextButton = nowPlayingOverlay(in: app).buttons["Up Next"].firstMatch
        assertNowPlayingControlIsReachable(upNextButton, named: "Up Next control", in: app)
        upNextButton.tap()

        assertExists(app.navigationBars["Up Next"], named: "Up Next sheet")
        let rowQueries = Self.seededQueuedEpisodeRowIdentifiers.map {
            app.buttons.matching(identifier: $0)
        }
        let rows = rowQueries.map { query in
            query.allElementsBoundByIndex.first(where: \.isHittable) ?? query.firstMatch
        }
        for (index, query) in rowQueries.enumerated() {
            XCTAssertGreaterThanOrEqual(
                query.count,
                2,
                "Queued episode \(index + 1) should exist in the Inbox and Up Next sheet."
            )
            let row = rows[index]
            assertExists(row, named: "queued episode \(index + 1)")
        }

        app.buttons["Edit"].tap()
        let reorderHandles = app.images.matching(NSPredicate(format: "label == %@", "drag"))
        XCTAssertEqual(reorderHandles.count, 3, "Every queued row should expose a reorder handle.")
        let reorderStart = reorderHandles.element(boundBy: 2)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let reorderEnd = reorderHandles.element(boundBy: 0)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        reorderStart.press(
            forDuration: 1,
            thenDragTo: reorderEnd,
            withVelocity: .slow,
            thenHoldForDuration: 0.4
        )
        let thirdMovedBeforeFirst = NSPredicate { _, _ in
            rows[0].exists && rows[2].exists && rows[2].frame.midY < rows[0].frame.midY
        }
        let reorderExpectation = XCTNSPredicateExpectation(
            predicate: thirdMovedBeforeFirst,
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reorderExpectation], timeout: 5),
            .completed,
            "Dragging the third queued row should persist its new visible order."
        )
        app.buttons["Done"].tap()

        rows[1].swipeLeft()
        let deleteButton = app.buttons["Delete"].firstMatch
        assertExists(deleteButton, named: "queued row delete action")
        deleteButton.tap()
        let deletedFromQueue = NSPredicate { _, _ in rowQueries[1].count == 1 }
        let deleteExpectation = XCTNSPredicateExpectation(predicate: deletedFromQueue, object: app)
        XCTAssertEqual(
            XCTWaiter.wait(for: [deleteExpectation], timeout: 5),
            .completed,
            "Deleting from Up Next should remove only the sheet copy of the queued episode."
        )

        app.buttons["Clear"].tap()
        let confirmClearButton = app.buttons["Clear Up Next"].firstMatch
        assertExists(confirmClearButton, named: "clear queue confirmation")
        confirmClearButton.tap()
        assertExists(app.staticTexts["Nothing Up Next"], named: "empty Up Next state")
    }

    @MainActor
    func testSeededNowPlayingAirPlayPickerCanOpen() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("AirPlay route-picker presentation is a physical-device check; see docs/simulator-limitations.md.")
        #else
        let app = makeSeededApp()
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        let pauseButton = overlay.buttons["Pause"].firstMatch
        if pauseButton.waitForExistence(timeout: 5) {
            pauseButton.tap()
        }

        let airPlayControl = overlay.buttons["AirPlay"].firstMatch
        assertExists(airPlayControl, named: "AirPlay control")
        let routeValue = (airPlayControl.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(routeValue.isEmpty, "AirPlay control should expose a route before opening the picker")

        airPlayControl.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let routePickerPresented = NSPredicate { _, _ in
            self.routePickerDestinationExists(in: app) || self.routePickerDestinationExists(in: springboard)
        }
        let expectation = XCTNSPredicateExpectation(predicate: routePickerPresented, object: app)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        attachSmokeScreenshot(named: "airplay_route_picker")
        XCTAssertEqual(result, .completed)
        #endif
    }

    @MainActor
    func testSeededNowPlayingAccessibilityXXXLControlsAreReachable() throws {
        let app = makeSeededApp(
            preferredContentSizeCategoryName: "UICTContentSizeCategoryAccessibilityXXXL"
        )
        app.launch()

        openSeededNowPlaying(in: app)
        let overlay = nowPlayingOverlay(in: app)
        assertNowPlayingControlIsReachable(playbackProgress(in: app), named: "Playback Progress control", in: app)

        let pauseButton = overlay.buttons["Pause"].firstMatch
        let playButton = overlay.buttons["Play"].firstMatch
        let playPauseButton = pauseButton.waitForExistence(timeout: 2) ? pauseButton : playButton
        assertNowPlayingControlIsReachable(playPauseButton, named: "Play/Pause control", in: app)

        let skipBackButton = overlay.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Skip Back")
        ).firstMatch
        assertNowPlayingControlIsReachable(skipBackButton, named: "Skip Back control", in: app)

        let skipForwardButton = overlay.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Skip Forward")
        ).firstMatch
        assertNowPlayingControlIsReachable(skipForwardButton, named: "Skip Forward control", in: app)

        assertNowPlayingControlIsReachable(app.buttons["Playback Speed"], named: "Playback Speed control", in: app)
        assertNowPlayingControlIsReachable(app.buttons["AirPlay"], named: "AirPlay control", in: app)
        assertNowPlayingControlIsReachable(app.buttons["Sleep Timer"], named: "Sleep Timer control", in: app)
        assertNowPlayingControlIsReachable(app.buttons["Up Next"], named: "Up Next control", in: app)
        assertPlayerUtilityControlHeightsAreBalanced(in: app)
        attachSmokeScreenshot(named: "now_playing_expanded_accessibility_xxxl")
    }

    @MainActor
    private func verifyAddPodcastRSSClipboardPrefill(
        forcesDarkMode: Bool,
        forcesLightMode: Bool,
        screenshotName: String
    ) throws {
        let pastedFeedURL = "https://example.com/feed.xml"
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
        seedsFailedDownload: Bool = false,
        seedsTranscriptionModel: Bool = false,
        seedsCompletedTranscript: Bool = false,
        completesTranscriptRequests: Bool = false,
        seedsCompletedAdAnalysis: Bool = false,
        seedsAdAnalysisSpanAtStart: Bool = false,
        seedsStaleAdAnalysis: Bool = false,
        seedsOutdatedPolicyAdAnalysis: Bool = false,
        seedsLowConfidenceAdAnalysis: Bool = false,
        seedsBadAudioURL: Bool = false,
        seedsEpisodeProgress: Bool = false,
        seedsArtworkPreview: Bool = false,
        seedsVariedArtworkPreviews: Bool = false,
        seedsPerEpisodeVoiceBoost: Bool = false,
        seedsLongShowNotes: Bool = false,
        seedsUpNextQueue: Bool = false,
        audioDurationSeconds: Int? = nil,
        skipIntroSeconds: Double? = nil,
        extraFeedCount: Int = 0,
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
        if optionalEnvironmentValue("OPENCAST_FRAME_PROBE") == "1" {
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
        if seedsFailedDownload {
            app.launchArguments.append("--opencast-seed-failed-download")
            app.launchEnvironment["OPENCAST_SEED_FAILED_DOWNLOAD"] = "1"
        }
        if seedsTranscriptionModel {
            app.launchArguments.append("--opencast-seed-transcription-model")
            app.launchEnvironment["OPENCAST_SEED_TRANSCRIPTION_MODEL"] = "1"
        }
        if seedsCompletedTranscript {
            app.launchArguments.append("--opencast-seed-completed-transcript")
            app.launchEnvironment["OPENCAST_SEED_COMPLETED_TRANSCRIPT"] = "1"
        }
        if completesTranscriptRequests {
            app.launchArguments.append("--opencast-complete-transcript-requests")
            app.launchEnvironment["OPENCAST_UI_TEST_COMPLETE_TRANSCRIPT_REQUESTS"] = "1"
            app.launchArguments.append("--opencast-apple-speech-fake-assets=installed")
            app.launchEnvironment["OPENCAST_APPLE_SPEECH_FAKE_ASSETS"] = "installed"
        }
        if seedsCompletedAdAnalysis {
            app.launchArguments.append("--opencast-seed-completed-ad-analysis")
            app.launchEnvironment["OPENCAST_SEED_COMPLETED_AD_ANALYSIS"] = "1"
        }
        if seedsAdAnalysisSpanAtStart {
            app.launchArguments.append("--opencast-seed-ad-analysis-span-at-start")
            app.launchEnvironment[Self.seedAdAnalysisSpanAtStartEnvironmentKey] = "1"
        }
        if seedsStaleAdAnalysis {
            app.launchEnvironment["OPENCAST_SEED_STALE_AD_ANALYSIS"] = "1"
        }
        if seedsOutdatedPolicyAdAnalysis {
            app.launchEnvironment["OPENCAST_SEED_OUTDATED_POLICY_AD_ANALYSIS"] = "1"
        }
        if seedsLowConfidenceAdAnalysis {
            app.launchEnvironment["OPENCAST_SEED_LOW_CONFIDENCE_AD_ANALYSIS"] = "1"
        }
        if seedsEpisodeProgress {
            app.launchArguments.append("--opencast-seed-episode-progress")
            app.launchEnvironment["OPENCAST_SEED_EPISODE_PROGRESS"] = "1"
        }
        if seedsArtworkPreview {
            app.launchEnvironment["OPENCAST_SEED_ARTWORK_PREVIEW"] = "1"
        }
        if seedsVariedArtworkPreviews {
            app.launchEnvironment["OPENCAST_SEED_VARIED_ARTWORK_PREVIEWS"] = "1"
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
        if seedsUpNextQueue {
            app.launchEnvironment["OPENCAST_SEED_UP_NEXT_QUEUE"] = "1"
        }
        if let audioDurationSeconds = audioDurationSeconds ?? (seedsUpNextQueue ? 600 : nil) {
            app.launchEnvironment["OPENCAST_SEED_AUDIO_DURATION_SECONDS"] = String(audioDurationSeconds)
        }
        if let skipIntroSeconds {
            app.launchEnvironment["OPENCAST_SEED_SKIP_INTRO_SECONDS"] = String(skipIntroSeconds)
        }
        if extraFeedCount > 0 {
            app.launchEnvironment["OPENCAST_SEED_EXTRA_FEED_COUNT"] = String(extraFeedCount)
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
    private func clearSearchFieldForRevampSmoke(
        _ searchField: XCUIElement
    ) {
        searchField.tap()
        let clearButton = searchField.buttons["Clear text"].firstMatch
        if clearButton.waitForExistence(timeout: 2), clearButton.isHittable {
            clearButton.tap()
            return
        }
        guard let value = searchField.value as? String, !value.isEmpty else {
            return
        }
        searchField.typeText(
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: value.count + 2
            )
        )
    }

    @MainActor
    private func makeCompletedOnboardingApp(
        libraryLoadDelayMilliseconds: Int? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--opencast-ui-testing")
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        if let libraryLoadDelayMilliseconds {
            app.launchEnvironment["OPENCAST_UI_TEST_LIBRARY_LOAD_DELAY_MILLISECONDS"] = String(libraryLoadDelayMilliseconds)
        }
        return app
    }

    @MainActor
    private func makeOnboardingApp(
        forcesDarkMode: Bool,
        seedsLibrary: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-onboarding"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_ONBOARDING"] = "1"
        if seedsLibrary {
            app.launchArguments.append("--opencast-seed-ui-library")
            app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        }
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
    private func artworkPreviewPixelSummary(from screenshot: XCUIScreenshot) throws -> ArtworkPreviewPixelSummary {
        guard let image = UIImage(data: screenshot.pngRepresentation),
              let cgImage = image.cgImage
        else {
            throw XCTSkip("Could not decode row screenshot for artwork preview smoke check.")
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            throw XCTSkip("Could not draw row screenshot for artwork preview smoke check.")
        }

        var previewPixels = 0
        var placeholderPixels = 0
        let scanWidth = max(width / 3, 1)
        for y in 0..<height {
            for x in 0..<scanWidth {
                let offset = (y * width + x) * bytesPerPixel
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]

                if red > 200, green < 220, blue < 120 {
                    previewPixels += 1
                }
                if red < 110, green > 100, blue > 110 {
                    placeholderPixels += 1
                } else if red > 40, red < 140, green < 140, blue > 120 {
                    placeholderPixels += 1
                }
            }
        }

        return ArtworkPreviewPixelSummary(
            previewPixels: previewPixels,
            placeholderPixels: placeholderPixels
        )
    }

    @MainActor
    private func dominantArtworkPreviewPixelSummary(
        for element: XCUIElement,
        timeout: TimeInterval = 8
    ) throws -> ArtworkPreviewPixelSummary {
        let deadline = Date.now.addingTimeInterval(timeout)
        var latestSummary: ArtworkPreviewPixelSummary?

        while Date.now < deadline {
            let summary = try artworkPreviewPixelSummary(from: element.screenshot())
            latestSummary = summary
            if summary.previewPixels > summary.placeholderPixels * 8 {
                return summary
            }

            RunLoop.current.run(until: Date.now.addingTimeInterval(0.25))
        }

        if let latestSummary {
            return latestSummary
        }

        return try artworkPreviewPixelSummary(from: element.screenshot())
    }

    @MainActor
    private func assertCompactCardPlateIsInset(
        named name: String,
        verticalBand: (start: Double, end: Double) = (start: 0.18, end: 0.55),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let extents = compactCardPlateExtents(
            from: XCUIScreen.main.screenshot(),
            verticalBand: verticalBand
        ) else {
            XCTFail("Could not detect \(name).", file: file, line: line)
            return
        }

        let minimumMargin = max(20, Int(Double(extents.imageWidth) * 0.02))
        XCTAssertGreaterThanOrEqual(
            extents.leftMargin,
            minimumMargin,
            "\(name) should keep the compact List/card leading inset.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            extents.rightMargin,
            minimumMargin,
            "\(name) should keep the compact List/card trailing inset.",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            Double(extents.plateWidth) / Double(extents.imageWidth),
            0.97,
            "\(name) should not render as a full-width compact plate.",
            file: file,
            line: line
        )
    }

    @MainActor
    private func compactCardPlateExtents(
        from screenshot: XCUIScreenshot,
        verticalBand: (start: Double, end: Double)
    ) -> (imageWidth: Int, plateWidth: Int, leftMargin: Int, rightMargin: Int)? {
        guard let image = UIImage(data: screenshot.pngRepresentation),
              let cgImage = image.cgImage
        else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            return nil
        }

        let scanStartY = max(0, Int(Double(height) * verticalBand.start))
        let scanEndY = min(height, Int(Double(height) * verticalBand.end))
        guard scanEndY > scanStartY else {
            return nil
        }
        let darkPixelThreshold = max(8, Int(Double(scanEndY - scanStartY) * 0.12))
        var detectedColumns: [Int] = []

        for x in 0..<width {
            var darkPixelCount = 0
            for y in scanStartY..<scanEndY {
                let offset = (y * width + x) * bytesPerPixel
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                let luminance = (Int(red) + Int(green) + Int(blue)) / 3
                let channelSpread = Int(max(red, green, blue)) - Int(min(red, green, blue))

                if luminance >= 18, luminance <= 72, channelSpread <= 24 {
                    darkPixelCount += 1
                }
            }

            if darkPixelCount >= darkPixelThreshold {
                detectedColumns.append(x)
            }
        }

        guard let left = detectedColumns.min(), let right = detectedColumns.max() else {
            return nil
        }

        return (
            imageWidth: width,
            plateWidth: right - left + 1,
            leftMargin: left,
            rightMargin: width - right - 1
        )
    }

    private struct ArtworkPreviewPixelSummary {
        let previewPixels: Int
        let placeholderPixels: Int
    }

    @MainActor
    private func seededEpisodeRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Self.seededEpisodeRowIdentifier).firstMatch
    }

    @MainActor
    private func episodePlaybackControl(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "Episode Playback Control").firstMatch
    }

    @MainActor
    private func liveAdAnalysisEpisodeRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Self.liveAdAnalysisEpisodeRowIdentifier).firstMatch
    }

    @MainActor
    private func seededExtraEpisodeRow(in app: XCUIApplication, index: Int) -> XCUIElement {
        app.buttons.matching(identifier: "episode-row-ui-test-extra-episode-\(index)").firstMatch
    }

    @MainActor
    private func seededCompletedEpisodeRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Self.seededCompletedEpisodeRowIdentifier).firstMatch
    }

    @MainActor
    private func openTranscriptOptionsMenu(in app: XCUIApplication) {
        let menuButton = app.buttons["Transcript Options"]
        assertExists(menuButton, named: "Transcript Options menu button")
        menuButton.tap()
    }

    @MainActor
    private func dismissTranscriptOptionsMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
    }

    @MainActor
    private func dismissContextualMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
    }

    @MainActor
    private func seededSubscriptionRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.seededSubscriptionRowIdentifier).firstMatch
    }

    @MainActor
    private func pullDownToSearch(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func requireArtifactPath(environmentKey: String) throws -> String {
        guard let path = optionalEnvironmentValue(environmentKey)
        else {
            throw XCTSkip("Set \(environmentKey) to run the saved live Worker ad-analysis transcript screenshot smoke.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Saved live Worker ad-analysis artifact is missing at \(path).")
        }
        return path
    }

    private func requireEnvironmentValue(_ environmentKey: String, skipMessage: String) throws -> String {
        guard let value = optionalEnvironmentValue(environmentKey) else {
            throw XCTSkip(skipMessage)
        }
        return value
    }

    private func optionalEnvironmentValue(_ environmentKey: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let environmentValues = [
            environment[environmentKey],
            environment["TEST_RUNNER_\(environmentKey)"]
        ]
        if let value = environmentValues
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return value
        }

        guard environmentKey == Self.adAnalysisClientTokenEnvironmentKey,
              FileManager.default.fileExists(atPath: Self.localAdAnalysisClientTokenFilePath),
              let fileValue = try? String(contentsOfFile: Self.localAdAnalysisClientTokenFilePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !fileValue.isEmpty
        else {
            return nil
        }
        return fileValue
    }

    @MainActor
    private func tapBackButton(in app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
    }

    @MainActor
    private func swipeBack(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func assertNowPlayingOverlay(in app: XCUIApplication) {
        assertExists(nowPlayingOverlay(in: app), named: "Now Playing overlay")
    }

    @MainActor
    private func dismissTranscriptSheetAndWaitForNowPlaying(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let transcriptNavigationBar = app.navigationBars["Transcript"]
        assertExists(
            transcriptNavigationBar,
            named: "transcript sheet navigation bar",
            file: file,
            line: line
        )
        let dismissalStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07))
        let dismissalEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        dismissalStart.press(forDuration: 0.05, thenDragTo: dismissalEnd)
        assertDoesNotExist(
            transcriptNavigationBar,
            named: "transcript sheet after dismissal",
            timeout: 10,
            file: file,
            line: line
        )
        assertNowPlayingOverlay(in: app)

        let titleButton = nowPlayingOverlay(in: app).buttons["Now Playing Episode Title"].firstMatch
        assertHittable(
            titleButton,
            named: "Now Playing episode title after transcript sheet dismissal",
            timeout: 10,
            file: file,
            line: line
        )
    }

    @MainActor
    private func openCurrentEpisodeDetailFromNowPlaying(in app: XCUIApplication) {
        let overlay = nowPlayingOverlay(in: app)
        assertExists(overlay, named: "Now Playing overlay before opening episode detail")
        let titleButton = overlay.buttons["Now Playing Episode Title"].firstMatch
        assertHittable(titleButton, named: "Now Playing episode title button")
        titleButton.tap()
        assertExists(
            episodePlaybackControl(in: app),
            named: "episode detail after tapping Now Playing title",
            timeout: 10
        )
    }

    @MainActor
    private func openPodcastPlaybackSettings(in app: XCUIApplication) {
        let actionsButton = app.buttons["Podcast Actions"]
        assertHittable(actionsButton, named: "podcast actions menu")
        actionsButton.tap()
        let playbackSettings = app.buttons["Skip Intro & Outro…"]
        assertHittable(playbackSettings, named: "Skip Intro & Outro menu action")
        playbackSettings.tap()
        assertExists(
            app.navigationBars["Skip Intro & Outro"],
            named: "podcast playback settings sheet"
        )
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with replacement: String) {
        assertHittable(field, named: "duration field to replace")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        let existingValue = (field.value as? String) ?? ""
        field.typeText(String(
            repeating: XCUIKeyboardKey.delete.rawValue,
            count: existingValue.count + 2
        ))
        field.typeText(replacement)
    }

    @MainActor
    private func openEpisodeDetailFromContextMenu(
        _ row: XCUIElement,
        in app: XCUIApplication,
        named name: String,
        expectsGoToShow: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertExists(row, named: "\(name) row", file: file, line: line)
        row.press(forDuration: 1.2)

        let detailsAction = app.buttons["View Episode Details"]
        assertExists(detailsAction, named: "\(name) details context action", file: file, line: line)
        if expectsGoToShow {
            assertExists(
                app.buttons["Go to Show"],
                named: "\(name) Go to Show context action",
                file: file,
                line: line
            )
        } else {
            assertDoesNotExist(
                app.buttons["Go to Show"],
                named: "\(name) duplicate Go to Show context action",
                file: file,
                line: line
            )
        }
        // The shared row menu carries these actions on every surface.
        assertExists(
            app.buttons["Play Next"].firstMatch,
            named: "\(name) Play Next context action",
            file: file,
            line: line
        )
        assertExists(
            app.buttons["Play Last"].firstMatch,
            named: "\(name) Play Last context action",
            file: file,
            line: line
        )
        assertExists(
            app.buttons["Detect Ads"].firstMatch,
            named: "\(name) Detect Ads context action",
            file: file,
            line: line
        )
        assertExists(
            app.buttons["Download"].firstMatch,
            named: "\(name) Download context action",
            file: file,
            line: line
        )
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name) context preview"
        attachment.lifetime = .keepAlways
        add(attachment)

        detailsAction.tap()
        assertExists(app.buttons["Play Episode"], named: "\(name) episode detail", file: file, line: line)
        assertDoesNotExist(nowPlayingOverlay(in: app), named: "\(name) Now Playing overlay", file: file, line: line)
    }

    @MainActor
    private func assertPlayerUtilityControlsExist(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertExists(app.buttons["Playback Speed"], named: "Playback Speed control")
        let airPlayControl = app.buttons["AirPlay"].firstMatch
        assertExists(airPlayControl, named: "AirPlay control", file: file, line: line)
        let airPlayButtonCount = app.buttons.matching(NSPredicate(format: "label == %@", "AirPlay")).count
        XCTAssertEqual(airPlayButtonCount, 1, "AirPlay should expose one accessible control", file: file, line: line)
        assertExists(app.buttons["Sleep Timer"], named: "Sleep Timer control")
        let upNextControl = app.buttons["Up Next"].firstMatch
        assertExists(upNextControl, named: "Up Next control", file: file, line: line)
        let upNextValue = (upNextControl.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(
            upNextValue.isEmpty,
            "Up Next should expose its queue state as an accessibility value",
            file: file,
            line: line
        )

        let routeValue = (airPlayControl.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(
            routeValue.isEmpty,
            "AirPlay control should expose the current route as its accessibility value",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertPlayerUtilityControlHeightsAreBalanced(
        in app: XCUIApplication,
        tolerance: CGFloat = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let overlay = nowPlayingOverlay(in: app)
        let controls = [
            (name: "Playback Speed", element: overlay.buttons["Playback Speed"].firstMatch),
            (name: "AirPlay", element: overlay.buttons["AirPlay"].firstMatch),
            (name: "Sleep Timer", element: overlay.buttons["Sleep Timer"].firstMatch),
            (name: "Up Next", element: overlay.buttons["Up Next"].firstMatch)
        ]

        for (name, control) in controls {
            assertExists(control, named: "\(name) control", file: file, line: line)
        }

        let heights = controls.map { $0.element.frame.height }
        let minimumHeight = heights.min() ?? 0
        let maximumHeight = heights.max() ?? 0
        let frameSummary = controls
            .map { "\($0.name)=\($0.element.frame)" }
            .joined(separator: ", ")

        XCTAssertLessThanOrEqual(
            maximumHeight - minimumHeight,
            tolerance,
            "Utility control heights should stay balanced. \(frameSummary)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertNowPlayingControlIsReachable(
        _ element: XCUIElement,
        named name: String,
        in app: XCUIApplication,
        maxSwipes: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(name) should exist", file: file, line: line)
        for _ in 0..<maxSwipes where !element.isHittable {
            app.swipeUp()
        }

        XCTAssertTrue(element.isHittable, "\(name) should be reachable", file: file, line: line)
    }

    @MainActor
    private func openSeededNowPlayingSoundLab(in app: XCUIApplication) {
        openSeededNowPlaying(in: app)
        revealNowPlayingSoundLab(in: app)
        assertExists(nowPlayingSoundLabPanel(in: app), named: "Now Playing Sound Lab panel")
    }

    @MainActor
    private func openSeededNowPlaying(in app: XCUIApplication) {
        openInbox(in: app)

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
    }

    @MainActor
    private func openSeededEpisodeDetail(in app: XCUIApplication) {
        openInbox(in: app)

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        openCurrentEpisodeDetailFromNowPlaying(in: app)
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
    private func holdNowPlayingDismissDrag(
        in app: XCUIApplication,
        endY: CGFloat,
        holdDuration: TimeInterval,
        velocity: XCUIGestureVelocity = .slow
    ) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: velocity,
            thenHoldForDuration: holdDuration
        )
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
    private func revealNowPlayingSoundLab(in app: XCUIApplication) {
        let artwork = nowPlayingArtwork(in: app)
        assertExists(artwork, named: "Now Playing artwork before Sound Lab reveal")
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.52))
        let end = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.48))
        start.press(forDuration: 0.10, thenDragTo: end)
    }

    @MainActor
    private func closeNowPlayingSoundLab(in app: XCUIApplication) {
        let artwork = nowPlayingArtwork(in: app)
        assertExists(artwork, named: "Now Playing artwork before closing Sound Lab")
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.52))
        let end = start.withOffset(CGVector(dx: max(180, artwork.frame.width * 2.2), dy: 0))
        start.press(forDuration: 0.06, thenDragTo: end)
    }

    @MainActor
    private func nowPlayingOverlay(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Now Playing"]
    }

    @MainActor
    private func finishedPlayback(in element: XCUIElement) -> XCUIElement {
        element.descendants(matching: .any)["Finished Playback"]
    }

    @MainActor
    private func nowPlayingArtwork(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Now Playing Artwork"]
    }

    @MainActor
    private func nowPlayingSoundLabPanel(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Now Playing Sound Lab"]
    }

    @MainActor
    private func assertAdFreePassControlSitsInProtectedPanelSpace(
        _ element: XCUIElement,
        panel: XCUIElement,
        stage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            panel.frame.contains(element.frame),
            "\(stage) ad-free pass control should stay inside the Sound Lab panel",
            file: file,
            line: line
        )
        // Mirrors NowPlayingSoundLabLayout(panelWidth:): the artwork rail plus
        // its gutter is the panel's protected leading space — controls must
        // clear the rail, wherever layout tuning puts the row's own insets.
        let artworkRailWidth = min(54, max(40, panel.frame.width * 0.18))
        let protectedLeadingSpace = artworkRailWidth + 4
        XCTAssertGreaterThanOrEqual(
            element.frame.minX,
            panel.frame.minX + protectedLeadingSpace - 0.5,
            "\(stage) ad-free pass control should clear the artwork rail",
            file: file,
            line: line
        )
    }

    @MainActor
    private func captureAdFreePassControlScreenshot(
        stage: String,
        buttonLabel: String,
        statusFragment: String,
        screenshotName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = makeSeededApp()
        app.launchEnvironment[Self.adFreePassPresentationOverrideEnvironmentKey] = stage
        app.launch()

        openSeededNowPlayingSoundLab(in: app)
        let panel = nowPlayingSoundLabPanel(in: app)
        let passButton = app.buttons.matching(identifier: "Skip Promos & Ads").firstMatch

        assertExists(passButton, named: "\(stage) ad-free pass button", file: file, line: line)
        XCTAssertTrue(passButton.label.contains(buttonLabel), file: file, line: line)
        // The row is fixed-footprint: no visible status line, so the status
        // lives entirely in the accessibility value.
        XCTAssertTrue(
            ((passButton.value as? String) ?? "").contains(statusFragment),
            "\(stage) ad-free pass button should expose its status as an accessibility value",
            file: file,
            line: line
        )
        assertAdFreePassControlSitsInProtectedPanelSpace(passButton, panel: panel, stage: stage, file: file, line: line)
        attachSmokeScreenshot(named: screenshotName)

        app.terminate()
    }

    @MainActor
    private func playbackProgress(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Playback Progress"]
    }

    @MainActor
    private func autoSkipPill(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Skipped promo"]
    }

    @MainActor
    private func autoSkipSettingsToggle(in app: XCUIApplication) -> XCUIElement {
        app.switches["Auto-Skip Promos & Ads"].firstMatch
    }

    @MainActor
    @discardableResult
    private func waitForPlaybackElapsed(
        _ progress: XCUIElement,
        atLeast minimumElapsed: TimeInterval,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TimeInterval {
        waitForPlaybackElapsed(
            progress,
            matching: { $0 >= minimumElapsed },
            timeout: timeout,
            failureDescription: "Expected Playback Progress elapsed time >= \(minimumElapsed)s",
            file: file,
            line: line
        )
    }

    @MainActor
    @discardableResult
    private func waitForPlaybackElapsed(
        _ progress: XCUIElement,
        in range: Range<TimeInterval>,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TimeInterval {
        waitForPlaybackElapsed(
            progress,
            matching: { range.contains($0) },
            timeout: timeout,
            failureDescription: "Expected Playback Progress elapsed time in \(range.lowerBound)..<\(range.upperBound)s",
            file: file,
            line: line
        )
    }

    @MainActor
    private func waitForPlaybackElapsed(
        _ progress: XCUIElement,
        matching predicate: (TimeInterval) -> Bool,
        timeout: TimeInterval,
        failureDescription: String,
        file: StaticString,
        line: UInt
    ) -> TimeInterval {
        let deadline = Date.now.addingTimeInterval(timeout)
        var lastElapsed: TimeInterval?
        var lastValue = progress.value as? String ?? "nil"

        while Date.now < deadline {
            lastValue = progress.value as? String ?? "nil"
            if let elapsed = playbackElapsedSeconds(from: lastValue) {
                lastElapsed = elapsed
                if predicate(elapsed) {
                    return elapsed
                }
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
        }

        XCTFail(
            "\(failureDescription), got elapsed=\(lastElapsed.map(String.init(describing:)) ?? "nil") value=\(lastValue)",
            file: file,
            line: line
        )
        return lastElapsed ?? 0
    }

    private func playbackElapsedSeconds(from accessibilityValue: String) -> TimeInterval? {
        guard let elapsedText = accessibilityValue.components(separatedBy: " elapsed").first else {
            return nil
        }

        let parts = elapsedText.split(separator: ":").compactMap { TimeInterval(String($0)) }
        switch parts.count {
        case 2:
            return parts[0] * 60 + parts[1]
        case 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default:
            return nil
        }
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
        containing requiredEvent: String? = nil,
        timeout: TimeInterval = 15
    ) -> String {
        let element = app.descendants(matching: .any)["Frame Pacing Summary"]
        let deadline = Date().addingTimeInterval(timeout)
        var value = ""
        while Date() < deadline {
            value = (element.value as? String) ?? ""
            let sessions = value.components(separatedBy: "session=").count - 1
            let hasRequiredEvent = requiredEvent.map(value.contains) ?? true
            if sessions >= expectedSessions, hasRequiredEvent {
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

    private func assertEventOrder(
        _ events: [String],
        in summary: String,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = summary.startIndex
        for event in events {
            guard let range = summary.range(
                of: event,
                range: searchStart..<summary.endIndex
            ) else {
                XCTFail(
                    "Missing or out-of-order \(event) for \(name): \(summary)",
                    file: file,
                    line: line
                )
                return
            }
            searchStart = range.upperBound
        }
    }

    @MainActor
    private func openLibrary(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openSection("Library", in: app, file: file, line: line)
    }

    @MainActor
    private func openGlobalSearch(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let searchField = app.searchFields.firstMatch
        if app.navigationBars["Search"].exists, searchField.exists {
            return searchField
        }

        openSection("Search", in: app, file: file, line: line)
        return presentedSearchField(
            in: app,
            navigationBarTitle: "Search",
            file: file,
            line: line
        )
    }

    @MainActor
    private func presentedSearchField(
        in app: XCUIApplication,
        navigationBarTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 2) {
            let searchButtons = app.navigationBars[navigationBarTitle].buttons.matching(
                NSPredicate(format: "label == %@", "Search")
            )
            assertExists(
                searchButtons.firstMatch,
                named: "search presentation button",
                file: file,
                line: line
            )
            let searchButton = searchButtons.allElementsBoundByIndex
                .filter(\.isHittable)
                .max { $0.frame.minX < $1.frame.minX }
                ?? searchButtons.firstMatch
            searchButton.tap()
        }
        assertExists(
            searchField,
            named: "search field",
            file: file,
            line: line
        )
        return searchField
    }

    @MainActor
    private func openInbox(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openSection("Inbox", in: app, file: file, line: line)
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

        let rootAddButton = app.navigationBars["opencast"].buttons["Add"]
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
            print("TRACE_ARMING \(environmentKey) \(seconds)s")
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

    private func requireManyArtworkPerformanceProbe() throws {
        let isEnabled = ProcessInfo.processInfo.environment[Self.manyArtworkPerformanceProbeEnvironmentKey] == "1"
        guard isEnabled || FileManager.default.fileExists(atPath: Self.manyArtworkPerformanceProbeFilePath) else {
            throw XCTSkip("Set \(Self.manyArtworkPerformanceProbeEnvironmentKey)=1 to run the many-artwork preview performance probe.")
        }
    }

    private func requireThisAmericanLifeReviewerPathProbe() throws {
        let isEnabled = ProcessInfo.processInfo.environment[Self.thisAmericanLifeReviewerPathProbeEnvironmentKey] == "1"
        guard isEnabled || FileManager.default.fileExists(atPath: Self.thisAmericanLifeReviewerPathProbeFilePath) else {
            throw XCTSkip("Set \(Self.thisAmericanLifeReviewerPathProbeEnvironmentKey)=1 or create \(Self.thisAmericanLifeReviewerPathProbeFilePath) to run the live This American Life reviewer-path UI tests.")
        }
    }

    @MainActor
    private func restIsScienceFirstEpisode(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.containing(.staticText, identifier: "The Rest Is Science").firstMatch
        if button.waitForExistence(timeout: 2) {
            return button
        }

        return app.cells.containing(.staticText, identifier: "The Rest Is Science").element
    }

    @MainActor
    private func thisAmericanLifeEpisodeRow(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.containing(.staticText, identifier: "This American Life").firstMatch
        if button.waitForExistence(timeout: 2) {
            return button
        }

        return app.cells.containing(.staticText, identifier: "This American Life").element
    }

    @MainActor
    private func openSettings(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openSection("Settings", in: app, file: file, line: line)
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
    private func syncStatusTitle(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label == %@ OR label == %@ OR label == %@ OR label == %@",
            "iCloud Sync On",
            "Checking iCloud",
            "iCloud Sync Off",
            "iCloud Sync Unavailable"
        )
        return app.staticTexts.matching(predicate).firstMatch
    }

    @MainActor
    private func routePickerDestinationExists(in app: XCUIApplication) -> Bool {
        let routeLabelPredicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "iPad",
            "AirPods",
            "Speaker",
            "Show More"
        )
        return app.descendants(matching: .any).matching(routeLabelPredicate).firstMatch.exists
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
    private func scrollUntilVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<maxSwipes where !isVisible(element, in: app) {
            app.swipeUp()
        }

        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(isVisible(element, in: app), file: file, line: line)
    }

    @MainActor
    private func isVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        element.exists && !element.frame.isEmpty && app.frame.intersects(element.frame)
    }

    @MainActor
    private func scrollUntilMiniPlayerDoesNotCover(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 3
    ) {
        let miniPlayer = app.buttons["Open Now Playing"]
        for _ in 0..<maxSwipes where element.exists && miniPlayer.exists && element.frame.intersects(miniPlayer.frame) {
            let overlap = max(element.frame.maxY - miniPlayer.frame.minY, 0)
            let dragDistance = min(max(overlap + 12, 36), app.frame.height * 0.2)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: -dragDistance))
            )
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
