import UIKit
import XCTest

final class OpenCastPadUITests: XCTestCase {
    private static let seededEpisodeRowIdentifier = "episode-row-ui-test-episode-1"
    private static let seededSubscriptionRowIdentifier = "subscription-row-https://example.com/ui-test-feed.xml"
    private static let hierarchyProbeEnvironmentKey = "OPENCAST_RUN_PAD_HIERARCHY_PROBE"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOptInPadHierarchyProbe() throws {
        try skipUnlessPad()
        try requireHierarchyProbeOptIn()

        let app = makeSeededApp()
        app.launch()

        attachHierarchyDump(named: "pad_default", in: app)
        openLibrary(in: app)
        attachHierarchyDump(named: "pad_library", in: app)

        openInbox(in: app)
        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()
        assertNowPlayingOverlay(in: app)
        dragDismissNowPlayingOverlay(in: app)
        attachHierarchyDump(named: "pad_accessory_visible", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        attachHierarchyDump(named: "pad_landscape", in: app)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSeededPadPrimaryTabsAvailableAndSwitch() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launch()

        assertExists(tabButton("Inbox", in: app), named: "Inbox tab button")
        assertExists(tabButton("Library", in: app), named: "Library tab button")
        assertExists(tabButton("Downloads", in: app), named: "Downloads tab button")
        assertExists(tabButton("Settings", in: app), named: "Settings tab button")

        openLibrary(in: app)
        assertExists(app.navigationBars["Library"], named: "Library navigation title")

        openSettings(in: app)
        assertExists(app.navigationBars["Settings"], named: "Settings navigation title")

        tabButton("Downloads", in: app).tap()
        assertExists(app.navigationBars["Downloads"], named: "Downloads navigation title")

        openInbox(in: app)
        assertExists(app.navigationBars["Inbox"], named: "Inbox navigation title")
    }

    @MainActor
    func testSeededPadLibraryGridTileOpensPodcastDetailPush() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launch()

        openSeededPodcastDetail(in: app)
        assertExists(app.staticTexts["Episodes"], named: "podcast detail episodes section")

        tapBackButton(in: app)
        assertExists(seededSubscriptionTile(in: app), named: "seeded library tile after back")
    }

    @MainActor
    func testSeededPadEpisodeTapShowsDetailBehindNowPlaying() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launch()

        openSeededPodcastDetail(in: app)
        let podcastEpisode = seededEpisodeRow(in: app)
        assertExists(podcastEpisode, named: "podcast detail seeded episode")
        podcastEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dragDismissNowPlayingOverlay(in: app)
        assertExists(app.buttons["Open Now Playing"], named: "mini-player after playing library episode")
        assertExists(app.staticTexts["Episodes"], named: "podcast detail underneath Now Playing")
    }

    @MainActor
    func testSeededPadLibraryEpisodeContextMenuOpensEpisodeDetail() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launch()

        openSeededPodcastDetail(in: app)
        openEpisodeDetailFromContextMenu(seededEpisodeRow(in: app), in: app, named: "podcast episode")
        assertExists(app.staticTexts["Show Notes"], named: "episode detail show notes heading")
        assertExists(app.buttons["Play Episode"], named: "episode detail action bar on iPad")
        attachSmokeScreenshot(named: "ipad_episode_detail")
    }

    @MainActor
    func testSeededPadLibraryGridTileContextMenuRemove() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        let tile = seededSubscriptionTile(in: app)
        assertExists(tile, named: "seeded library tile")
        tile.press(forDuration: 1.2)

        let menuRemove = app.buttons["Remove Podcast"].firstMatch
        assertExists(menuRemove, named: "tile Remove Podcast context action")
        menuRemove.tap()

        let confirmationRemove = app.buttons["Remove Podcast"].firstMatch
        assertExists(confirmationRemove, named: "tile Remove Podcast confirmation")
        confirmationRemove.tap()

        assertExists(app.staticTexts["No Subscriptions"], named: "empty Library after tile removal")
    }

    @MainActor
    func testSeededPadLibraryGridSwipeRemovalCanCancelAndConfirm() throws {
        try skipUnlessPad()
        let app = makeSeededApp()
        app.launch()
        openLibrary(in: app)
        let tile = seededSubscriptionTile(in: app)
        assertHittable(tile, named: "library tile before swipe")
        tile.swipeLeft()
        let confirmation = app.buttons["Remove & Clear History"]
        if !confirmation.waitForExistence(timeout: 2) {
            app.buttons["Remove Podcast Swipe Action"].firstMatch.tap()
        }
        assertExists(confirmation, named: "tile removal history choice")
        attachSmokeScreenshot(named: "ipad_grid_swipe_confirmation")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            // iPad confirmation popovers dismiss when tapped outside instead
            // of displaying the compact presentation's Cancel button.
            app.navigationBars["Library"].staticTexts["Library"].tap()
        }
        assertHittable(tile, named: "tile retained after cancelling removal")
        attachSmokeScreenshot(named: "ipad_grid_swipe_cancelled")
        tile.swipeLeft()
        if !confirmation.waitForExistence(timeout: 2) {
            app.buttons["Remove Podcast Swipe Action"].firstMatch.tap()
        }
        assertExists(confirmation, named: "second tile removal confirmation")
        app.buttons["Remove Podcast"].firstMatch.tap()
        assertExists(app.staticTexts["No Subscriptions"], named: "empty Library after confirmed swipe removal")
    }

    @MainActor
    func testSeededPadNarrowWindowKeepsToolbarActionsAvailable() throws {
        try skipUnlessPad()
        let app = makeSeededApp()
        app.launchArguments.append("--opencast-seed-completed-download")
        app.launch()
        assertExists(app.navigationBars["Inbox"], named: "Inbox before window resize")

        let window = app.windows.firstMatch
        let originalWidth = window.frame.width
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            .press(
                forDuration: 0.5,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.42))
            )
        XCTAssertLessThan(window.frame.width, 700, "The app window itself must be narrow, not just the Simulator scale")
        defer {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).doubleTap()
        }

        openLibrary(in: app)
        app.swipeUp()
        assertHittable(app.navigationBars["Library"].buttons["Add"], named: "pinned Add in narrow Library")
        attachSmokeScreenshot(named: "ipad_narrow_library_toolbar")

        openSection("Downloads", in: app)
        let toolbar = app.navigationBars["Downloads"]
        assertHittable(toolbar.buttons["Search"], named: "prioritized Search in narrow Downloads")
        assertHittable(toolbar.buttons["Edit"], named: "pinned Edit in narrow Downloads")
        toolbar.buttons["Edit"].tap()
        app.swipeUp()
        assertHittable(toolbar.buttons["Done"], named: "Done remains available after scrolling while editing")
        attachSmokeScreenshot(named: "ipad_narrow_downloads_editing")
        toolbar.buttons["Done"].tap()

        toolbar.buttons["Search"].tap()
        assertHittable(app.searchFields["Downloaded episodes"], named: "narrow Downloads search field")
        app.swipeUp()
        assertExists(app.searchFields["Downloaded episodes"], named: "search stays presented after scrolling")
        attachSmokeScreenshot(named: "ipad_narrow_downloads_search")
        XCTAssertLessThan(window.frame.width, originalWidth, "The toolbar checks must run in the resized window")
    }

    @MainActor
    func testSeededPadLibraryViewOptionsSwitchesLayouts() throws {
        try skipUnlessPad()
        let app = makeSeededApp(seedsLibraryNewEpisodes: true)
        app.launch()

        openLibrary(in: app)
        let list = libraryContainer("Library List", in: app)
        let grid = libraryContainer("Library Grid", in: app)

        // Automatic resolves to the grid at regular width.
        assertExists(grid, named: "Library grid under Automatic")
        assertDoesNotExist(list, named: "Library list under Automatic")

        chooseLibraryViewOption("List", in: app)
        assertExists(list, named: "Library list after choosing List")
        assertDoesNotExist(grid, named: "Library grid after choosing List", timeout: 5)
        assertExists(seededSubscriptionTile(in: app), named: "seeded library row")
        assertHittable(app.navigationBars["Library"].buttons["Add"], named: "pinned Add beside View Options")
        attachSmokeScreenshot(named: "ipad_library_list")

        chooseLibraryViewOption("Grid", in: app)
        assertExists(grid, named: "Library grid after choosing Grid")
        assertDoesNotExist(list, named: "Library list after choosing Grid", timeout: 5)

        chooseLibraryViewOption("Automatic", in: app)
        assertExists(grid, named: "Library grid after choosing Automatic at regular width")
        assertDoesNotExist(list, named: "Library list after choosing Automatic at regular width")

        // Automatic follows the window: narrowing it to compact width swaps
        // in the list with no further choice.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            .press(
                forDuration: 0.5,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.42))
            )
        defer {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).doubleTap()
        }
        XCTAssertLessThan(window.frame.width, 700, "The app window itself must be narrow, not just the Simulator scale")
        assertExists(list, named: "Library list under Automatic in a narrow window")
        assertDoesNotExist(grid, named: "Library grid under Automatic in a narrow window", timeout: 5)
        attachSmokeScreenshot(named: "ipad_library_narrow_automatic_list")
    }

    @MainActor
    func testSeededPadMiniPlayerAccessorySurvivesTabSwitchAndExpands() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launch()

        let inboxEpisode = seededEpisodeRow(in: app)
        assertExists(inboxEpisode, named: "seeded inbox episode")
        inboxEpisode.tap()

        assertNowPlayingOverlay(in: app)
        dragDismissNowPlayingOverlay(in: app)

        openLibrary(in: app)
        assertExists(app.buttons["Open Now Playing"], named: "mini-player after Library switch")
        openSettings(in: app)
        assertExists(app.buttons["Open Now Playing"], named: "mini-player after Settings switch")
        openInbox(in: app)

        let miniPlayer = app.buttons["Open Now Playing"]
        assertExists(miniPlayer, named: "mini-player after returning to Inbox")
        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
    }

    @MainActor
    func testSeededPadLibraryGridSurvivesRotation() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
        }

        openLibrary(in: app)
        assertExists(seededSubscriptionTile(in: app), named: "seeded library tile before rotation")

        XCUIDevice.shared.orientation = .landscapeLeft
        assertExists(seededSubscriptionTile(in: app), named: "seeded library tile in landscape")

        XCUIDevice.shared.orientation = .portrait
        assertExists(seededSubscriptionTile(in: app), named: "seeded library tile after portrait rotation")
    }

    @MainActor
    func testSeededPadSmokeScreenshots() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launch()

        openLibrary(in: app)
        assertExists(seededSubscriptionTile(in: app), named: "seeded library tile")
        attachSmokeScreenshot(named: "ipad_library_grid")

        openSeededPodcastDetail(in: app)
        attachSmokeScreenshot(named: "ipad_podcast_detail")

        let podcastEpisode = seededEpisodeRow(in: app)
        assertExists(podcastEpisode, named: "podcast detail seeded episode")
        podcastEpisode.tap()
        assertNowPlayingOverlay(in: app)
        attachSmokeScreenshot(named: "ipad_now_playing_expanded")

        dragDismissNowPlayingOverlay(in: app)
        openSettings(in: app)
        attachSmokeScreenshot(named: "ipad_settings_with_mini_player")
    }

    @MainActor
    func testSeededPadEpisodeDiagnosticsSheetAndShare() throws {
        try skipUnlessPad()

        let app = makeSeededApp()
        app.launchArguments.append("--opencast-seed-completed-download")
        app.launchEnvironment["OPENCAST_SEED_COMPLETED_DOWNLOAD"] = "1"
        app.launch()

        openSeededPodcastDetail(in: app)
        openEpisodeDetailFromContextMenu(seededEpisodeRow(in: app), in: app, named: "podcast episode")

        let actionsButton = app.buttons["Episode Actions"].firstMatch
        assertExists(actionsButton, named: "Episode Actions menu")
        actionsButton.tap()
        let diagnosticsEntry = app.buttons["Episode Diagnostics"].firstMatch
        assertExists(diagnosticsEntry, named: "Episode Diagnostics menu entry")
        diagnosticsEntry.tap()

        assertExists(app.navigationBars["Episode Diagnostics"].firstMatch, named: "diagnostics sheet on iPad")
        attachSmokeScreenshot(named: "ipad_episode_diagnostics")

        let shareButton = app.buttons["Download & Share Audio"].firstMatch
        assertExists(shareButton, named: "download and share audio action")
        shareButton.tap()

        // Scope the query to the remote share sheet's native header; a global
        // first-match query can miss its Link Presentation caption.
        let shareHeader = app.navigationBars["UIActivityContentView"].descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "LP.CaptionBar.TopCaption",
                "UI Test Show - Deterministic UI Episode"
            )
        ).firstMatch
        assertExists(shareHeader, named: "activity sheet with sanitized share filename")
        attachSmokeScreenshot(named: "ipad_episode_diagnostics_share")
    }

    // MARK: - Transcript recap on a PCC-eligible iPad

    /// Real Private Cloud Compute through the seeded in-memory library (the
    /// on-device store is untouched): a v3 transcript fixture pushed into the
    /// app container stands in for the two-line seed, both recap entries
    /// render, the first request passes the one-time disclosure, the recap
    /// arrives, and a citation tap seeks playback. Opt in with
    /// `TEST_RUNNER_OPENCAST_DEVICE_E2E=1`; `OPENCAST_RECAP_APPEARANCE`
    /// (light|dark), `OPENCAST_RECAP_FIXTURE` (path under Documents),
    /// `OPENCAST_RECAP_POSITION` and `OPENCAST_RECAP_AUDIO_DURATION` shape the
    /// run. Screenshots land as attachments named `ipad_recap_*`.
    @MainActor
    func testDeviceTranscriptRecapFromPrivateCloudCompute() throws {
        try skipUnlessPad()
        try skipUnlessDeviceRecapOptIn()
        let environment = ProcessInfo.processInfo.environment
        let appearance = Self.deviceRecapValue("OPENCAST_RECAP_APPEARANCE", in: environment) ?? "light"
        let fixture = Self.deviceRecapValue("OPENCAST_RECAP_FIXTURE", in: environment)
            ?? "TranscriptIntelligenceEvaluationInputs/fixtures/audio-illusion.json"
        let position = Self.deviceRecapValue("OPENCAST_RECAP_POSITION", in: environment) ?? "1200"
        let audioDuration = Self.deviceRecapValue("OPENCAST_RECAP_AUDIO_DURATION", in: environment) ?? "3527"

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-ui-library",
            "--opencast-seed-completed-transcript",
            "--opencast-seed-episode-progress",
            "--transcript-intelligence-enabled",
            appearance == "dark" ? "--opencast-force-dark-mode" : "--opencast-force-light-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_SEED_COMPLETED_TRANSCRIPT"] = "1"
        app.launchEnvironment["OPENCAST_SEED_EPISODE_PROGRESS"] = "1"
        app.launchEnvironment["OPENCAST_SEED_TRANSCRIPT_FIXTURE_PATH"] = fixture
        app.launchEnvironment["OPENCAST_SEED_EPISODE_PROGRESS_POSITION"] = position
        app.launchEnvironment["OPENCAST_SEED_AUDIO_DURATION_SECONDS"] = audioDuration
        app.launchEnvironment[appearance == "dark" ? "OPENCAST_FORCE_DARK_MODE" : "OPENCAST_FORCE_LIGHT_MODE"] = "1"
        app.launch()

        openInbox(in: app)
        openEpisodeDetailFromContextMenu(seededEpisodeRow(in: app), in: app, named: "seeded inbox episode")
        let readTranscript = app.buttons["Read Transcript"]
        var swipes = 0
        while !(readTranscript.waitForExistence(timeout: 1) && readTranscript.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        assertExists(readTranscript, named: "Read Transcript button")
        readTranscript.tap()
        assertExists(app.navigationBars["Transcript"], named: "Transcript route", timeout: 10)

        let recapList = app.descendants(matching: .any).matching(identifier: "Transcript Recap List").firstMatch

        // So far first: the first request on this launch passes the
        // disclosure, then a real PCC round trip.
        openDeviceRecapSheet(entry: "Recap So Far", in: app)
        let continueButton = app.buttons["Continue"].firstMatch
        if continueButton.waitForExistence(timeout: 5) {
            attachSmokeScreenshot(named: "ipad_recap_disclosure_\(appearance)")
            continueButton.tap()
        }
        assertExists(recapList, named: "so-far recap from Private Cloud Compute", timeout: 120)
        sleep(1)
        attachSmokeScreenshot(named: "ipad_recap_so_far_\(appearance)")
        attachHierarchyDump(named: "ipad_recap_so_far_hierarchy_\(appearance)", in: app)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Recap"].waitForNonExistence(timeout: 5), "Done should dismiss the recap sheet")

        openDeviceRecapSheet(entry: "Recap the Last 5 Minutes", in: app)
        assertExists(recapList, named: "last-five-minutes recap from Private Cloud Compute", timeout: 120)
        sleep(1)
        attachSmokeScreenshot(named: "ipad_recap_last_five_\(appearance)")
        attachHierarchyDump(named: "ipad_recap_last_five_hierarchy_\(appearance)", in: app)

        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play from")).firstMatch
        assertExists(chip, named: "citation chip")
        let chipLabel = chip.label
        chip.tap()
        XCTAssertTrue(
            app.navigationBars["Recap"].waitForNonExistence(timeout: 5),
            "tapping a citation should dismiss the recap sheet"
        )
        assertExists(app.navigationBars["Transcript"], named: "transcript route after seeking", timeout: 5)
        sleep(2)
        attachSmokeScreenshot(named: "ipad_recap_after_seek_\(appearance)")
        let seekNote = XCTAttachment(string: "tapped \(chipLabel)")
        seekNote.name = "ipad_recap_seek_\(appearance)"
        seekNote.lifetime = .keepAlways
        add(seekNote)
    }

    // MARK: - Transcript Ask on a PCC-eligible iPad

    /// Real Private Cloud Compute Ask through the seeded in-memory library:
    /// the pushed v3 transcript fixture stands in for the two-line seed, the
    /// first open passes the disclosure, a suggested question and a typed
    /// question each stream an answer with citation chips (or the calm
    /// declined / unanswerable state), and a chip tap seeks playback. Opt in
    /// with `TEST_RUNNER_OPENCAST_DEVICE_E2E=1`; the recap run's
    /// `OPENCAST_RECAP_*` keys shape the fixture, plus `OPENCAST_ASK_QUESTION`
    /// for the typed question. Screenshots land as `ipad_ask_*`.
    @MainActor
    func testDeviceTranscriptAskFromPrivateCloudCompute() throws {
        try skipUnlessPad()
        try skipUnlessDeviceRecapOptIn()
        let environment = ProcessInfo.processInfo.environment
        let appearance = Self.deviceRecapValue("OPENCAST_RECAP_APPEARANCE", in: environment) ?? "light"
        let fixture = Self.deviceRecapValue("OPENCAST_RECAP_FIXTURE", in: environment)
            ?? "TranscriptIntelligenceEvaluationInputs/fixtures/audio-illusion.json"
        let position = Self.deviceRecapValue("OPENCAST_RECAP_POSITION", in: environment) ?? "1200"
        let audioDuration = Self.deviceRecapValue("OPENCAST_RECAP_AUDIO_DURATION", in: environment) ?? "3527"
        let typedQuestion = Self.deviceRecapValue("OPENCAST_ASK_QUESTION", in: environment)
            ?? "Who set the world record for fastest drumming?"

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-ui-library",
            "--opencast-seed-completed-transcript",
            "--opencast-seed-episode-progress",
            "--transcript-intelligence-enabled",
            "--transcript-intelligence-ask-enabled",
            appearance == "dark" ? "--opencast-force-dark-mode" : "--opencast-force-light-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_SEED_COMPLETED_TRANSCRIPT"] = "1"
        app.launchEnvironment["OPENCAST_SEED_EPISODE_PROGRESS"] = "1"
        app.launchEnvironment["OPENCAST_SEED_TRANSCRIPT_FIXTURE_PATH"] = fixture
        app.launchEnvironment["OPENCAST_SEED_EPISODE_PROGRESS_POSITION"] = position
        app.launchEnvironment["OPENCAST_SEED_AUDIO_DURATION_SECONDS"] = audioDuration
        app.launchEnvironment[appearance == "dark" ? "OPENCAST_FORCE_DARK_MODE" : "OPENCAST_FORCE_LIGHT_MODE"] = "1"
        app.launch()

        openInbox(in: app)
        openEpisodeDetailFromContextMenu(seededEpisodeRow(in: app), in: app, named: "seeded inbox episode")
        let readTranscript = app.buttons["Read Transcript"]
        var swipes = 0
        while !(readTranscript.waitForExistence(timeout: 1) && readTranscript.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        assertExists(readTranscript, named: "Read Transcript button")
        readTranscript.tap()
        assertExists(app.navigationBars["Transcript"], named: "Transcript route", timeout: 10)

        openDeviceIntelligenceSheet(entry: "Ask About This Episode", navigationTitle: "Ask", in: app)
        let continueButton = app.buttons["Continue"].firstMatch
        if continueButton.waitForExistence(timeout: 5) {
            attachSmokeScreenshot(named: "ipad_ask_disclosure_\(appearance)")
            continueButton.tap()
        }
        let suggestion = app.buttons["What is this episode about?"].firstMatch
        assertExists(suggestion, named: "suggested question", timeout: 20)
        attachSmokeScreenshot(named: "ipad_ask_intro_\(appearance)")
        suggestion.tap()
        waitForDeviceAskOutcome(in: app, named: "first answer from Private Cloud Compute")
        sleep(1)
        attachSmokeScreenshot(named: "ipad_ask_first_answer_\(appearance)")
        attachHierarchyDump(named: "ipad_ask_first_answer_hierarchy_\(appearance)", in: app)

        let composer = app.textFields["Transcript Ask Composer"]
        assertExists(composer, named: "ask composer")
        composer.tap()
        composer.typeText(typedQuestion)
        let send = app.buttons["Transcript Ask Send"]
        assertExists(send, named: "send button")
        send.tap()
        waitForDeviceAskOutcome(in: app, named: "typed-question answer from Private Cloud Compute")
        sleep(1)
        attachSmokeScreenshot(named: "ipad_ask_second_answer_\(appearance)")
        attachHierarchyDump(named: "ipad_ask_second_answer_hierarchy_\(appearance)", in: app)

        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play from")).firstMatch
        guard chip.waitForExistence(timeout: 2) else {
            let note = XCTAttachment(string: "no citation chip to tap (declined or unanswerable)")
            note.name = "ipad_ask_seek_\(appearance)"
            note.lifetime = .keepAlways
            add(note)
            return
        }
        let chipLabel = chip.label
        chip.tap()
        XCTAssertTrue(
            app.navigationBars["Ask"].waitForNonExistence(timeout: 5),
            "tapping a citation should dismiss the ask sheet"
        )
        assertExists(app.navigationBars["Transcript"], named: "transcript route after seeking", timeout: 5)
        sleep(2)
        attachSmokeScreenshot(named: "ipad_ask_after_seek_\(appearance)")
        let seekNote = XCTAttachment(string: "tapped \(chipLabel)")
        seekNote.name = "ipad_ask_seek_\(appearance)"
        seekNote.lifetime = .keepAlways
        add(seekNote)
    }

    /// A real turn ends in chips, a decline, an unanswerable note, or a calm
    /// failure; any of those is an outcome worth capturing.
    @MainActor
    private func waitForDeviceAskOutcome(in app: XCUIApplication, named name: String) {
        let outcome = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR label BEGINSWITH %@",
            ["Transcript Ask Unanswerable", "Transcript Ask Unverified Note", "Transcript Ask Failure"],
            "Play from"
        )).firstMatch
        assertExists(outcome, named: name, timeout: 120)
    }

    private func skipUnlessDeviceRecapOptIn() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The recap device run needs a PCC-eligible iPad.")
        #else
        guard Self.deviceRecapValue("OPENCAST_DEVICE_E2E", in: ProcessInfo.processInfo.environment) == "1" else {
            throw XCTSkip("Set TEST_RUNNER_OPENCAST_DEVICE_E2E=1 to run the recap device test.")
        }
        #endif
    }

    private static func deviceRecapValue(_ key: String, in environment: [String: String]) -> String? {
        environment[key] ?? environment["TEST_RUNNER_\(key)"]
    }

    /// Menu entries are glass controls on the device: an element tap that
    /// does not open the sheet within a few seconds is retried by coordinate.
    @MainActor
    private func openDeviceRecapSheet(entry title: String, in app: XCUIApplication) {
        openDeviceIntelligenceSheet(entry: title, navigationTitle: "Recap", in: app)
    }

    @MainActor
    private func openDeviceIntelligenceSheet(entry title: String, navigationTitle: String, in app: XCUIApplication) {
        let menu = app.buttons["Transcript Options"]
        assertExists(menu, named: "Transcript Options menu")
        menu.tap()
        let entry = app.buttons[title]
        assertExists(entry, named: "\(title) entry", timeout: 8)
        entry.tap()
        if !app.navigationBars[navigationTitle].waitForExistence(timeout: 4) {
            if !entry.exists {
                menu.tap()
                assertExists(entry, named: "\(title) entry (retry)", timeout: 8)
            }
            entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        assertExists(app.navigationBars[navigationTitle], named: "\(navigationTitle.lowercased()) sheet for \(title)", timeout: 8)
    }

    @MainActor
    private func makeSeededApp(seedsLibraryNewEpisodes: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-ui-library",
            "--opencast-force-dark-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        if seedsLibraryNewEpisodes {
            app.launchEnvironment["OPENCAST_SEED_LIBRARY_NEW_EPISODES"] = "1"
        }
        return app
    }

    @MainActor
    private func skipUnlessPad() throws {
        guard Self.isPadDestination(
            environment: ProcessInfo.processInfo.environment,
            deviceModel: UIDevice.current.model,
            isPadIdiom: UIDevice.current.userInterfaceIdiom == .pad
        ) else {
            throw XCTSkip("OpenCastPadUITests require an iPad destination.")
        }
    }

    /// Pure destination decision so the hardware and override paths stay
    /// unit-covered (`OpenCastPadDestinationDecisionTests`). The runner's own
    /// idiom evaluated non-pad on a physical iPad during closeout, so the
    /// hardware model string and an explicit orchestrator override are
    /// affirmative disjuncts that don't depend on it.
    static func isPadDestination(
        environment: [String: String],
        deviceModel: String,
        isPadIdiom: Bool
    ) -> Bool {
        let simulatorName = environment["SIMULATOR_DEVICE_NAME"] ?? ""
        let isNamedIPadSimulator = simulatorName.range(of: "iPad", options: .caseInsensitive) != nil
        let isPadHardware = deviceModel.hasPrefix("iPad")
        let isForcedPad = environment["OPENCAST_FORCE_PAD"] == "1"
            || environment["TEST_RUNNER_OPENCAST_FORCE_PAD"] == "1"
        return isPadIdiom || isNamedIPadSimulator || isPadHardware || isForcedPad
    }

    private func requireHierarchyProbeOptIn() throws {
        let environment = ProcessInfo.processInfo.environment
        let isEnabled = environment[Self.hierarchyProbeEnvironmentKey] == "1"
            || environment["TEST_RUNNER_\(Self.hierarchyProbeEnvironmentKey)"] == "1"
        guard isEnabled else {
            throw XCTSkip("Set \(Self.hierarchyProbeEnvironmentKey)=1 to capture the iPad hierarchy probe.")
        }
    }

    @MainActor
    private func tabButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        visibleTabButton(title, in: app) ?? app.buttons[title].firstMatch
    }

    @MainActor
    private func openLibrary(in app: XCUIApplication) {
        openSection("Library", in: app)
    }

    @MainActor
    private func openInbox(in app: XCUIApplication) {
        openSection("Inbox", in: app)
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        openSection("Settings", in: app)
    }

    @MainActor
    private func openSeededPodcastDetail(in app: XCUIApplication) {
        openLibrary(in: app)
        let libraryPodcast = seededSubscriptionTile(in: app)
        assertExists(libraryPodcast, named: "seeded library tile")
        libraryPodcast.tap()
    }

    @MainActor
    private func seededSubscriptionTile(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.seededSubscriptionRowIdentifier).firstMatch
    }

    /// The Library's `Library List` or `Library Grid` container.
    @MainActor
    private func libraryContainer(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Picks a Library View Options layout entry. Entries match by label
    /// only: the menu button's value names the current layout.
    @MainActor
    private func chooseLibraryViewOption(_ title: String, in app: XCUIApplication) {
        let menu = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "Library View Options", "View Options")
        ).firstMatch
        assertHittable(menu, named: "Library View Options menu")
        menu.tap()
        let option = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        assertHittable(option, named: "\(title) view option")
        option.tap()
        XCTAssertTrue(option.waitForNonExistence(timeout: 5), "View Options should close after choosing \(title)")
    }

    @MainActor
    private func seededEpisodeRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Self.seededEpisodeRowIdentifier).firstMatch
    }

    @MainActor
    private func assertNowPlayingOverlay(in app: XCUIApplication) {
        assertExists(nowPlayingOverlay(in: app), named: "Now Playing overlay")
    }

    @MainActor
    private func nowPlayingOverlay(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Now Playing"]
    }

    @MainActor
    private func dragDismissNowPlayingOverlay(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func openEpisodeDetailFromContextMenu(
        _ row: XCUIElement,
        in app: XCUIApplication,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertExists(row, named: "\(name) row", file: file, line: line)
        row.press(forDuration: 1.2)

        let detailsAction = app.buttons["View Episode Details"]
        assertExists(detailsAction, named: "\(name) details context action", file: file, line: line)
        detailsAction.tap()
        assertExists(app.buttons["Play Episode"], named: "\(name) episode detail", file: file, line: line)
        assertDoesNotExist(nowPlayingOverlay(in: app), named: "\(name) Now Playing overlay", file: file, line: line)
    }

    @MainActor
    private func tapBackButton(in app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
    }

    @MainActor
    private func attachHierarchyDump(named name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
