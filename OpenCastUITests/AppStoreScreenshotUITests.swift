import UIKit
import XCTest

final class AppStoreScreenshotUITests: XCTestCase {
    private static let primaryFeedURL = "https://screenshots.opencast.example/orbit-report.xml"
    private static let primaryEpisodeID = "app-store-orbit-report-episode-1"
    private static let pipelineEpisodeID = "app-store-orbit-report-episode-3"
    private static let searchQuery = "light"
    private static let searchResultEpisodeIDs = [
        "app-store-greenhouse-hours-episode-1",
        "app-store-paper-lanterns-episode-1",
        primaryEpisodeID
    ]
    private static let upNextEpisodeIDs = [
        "app-store-kitchen-table-episode-1",
        "app-store-long-way-round-episode-1",
        "app-store-half-time-episode-1"
    ]
    private static let primarySubscriptionRowIdentifier = "subscription-row-\(primaryFeedURL)"
    private static let autoSkipPillArgument = "--opencast-pin-app-store-autoskip-pill"
    private static let forceOnboardingArgument = "--opencast-force-onboarding"
    private static let queueOverrideEnvironmentKey = "OPENCAST_UI_TEST_AD_FREE_PASS_QUEUE_OVERRIDE"
    private static let queueOverrideProgressEnvironmentKey = "OPENCAST_UI_TEST_AD_FREE_PASS_QUEUE_OVERRIDE_PROGRESS"

    // The runner's own idiom has evaluated non-pad on iPad destinations, so
    // this shares the pad tests' model-string-based decision.
    private var isPad: Bool {
        OpenCastPadUITests.isPadDestination(
            environment: ProcessInfo.processInfo.environment,
            deviceModel: UIDevice.current.model,
            isPadIdiom: UIDevice.current.userInterfaceIdiom == .pad
        )
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Capture order differs from App Store order. One base launch carries the
    // library, transcript, chapters, pipeline, search, Sound Lab, and Up Next
    // frames; the ad-skip hero, the welcome page, and the notification each
    // relaunch with their own flag so a pinned pill or forced onboarding
    // never leaks into another frame. The notification goes last so its
    // banner cannot contaminate anything. Playback is paused right after the
    // scrub into the sponsor read so the transcript's follow-along line stays
    // inside the flagged segment however long the earlier captures take.
    @MainActor
    func testAppStoreScreenshotSet() throws {
        let app = makeAppStoreScreenshotApp()
        app.launchEnvironment[Self.queueOverrideEnvironmentKey] = "transcribing:\(Self.pipelineEpisodeID)"
        app.launchEnvironment[Self.queueOverrideProgressEnvironmentKey] = "1822/2940"
        app.launch()

        startPrimaryEpisodePlayback(in: app)
        seekIntoSponsorRead(in: app)
        pausePlayback(in: app)
        openCurrentEpisodeDetailFromNowPlaying(in: app)
        openTranscriptFromEpisodeDetail(in: app)
        assertExists(sponsorTranscriptRow(in: app), named: "Bottomless Mug sponsor transcript row", timeout: 10)
        capture(iphone: "app_store_02_transcript", ipad: "app_store_03_transcript", in: app)

        tapBackButton(in: app)
        assertExists(app.buttons["Play Episode"], named: "episode detail after transcript", timeout: 10)
        let chaptersCard = element(withIdentifier: "Episode Chapters Card", in: app)
        scrollToRevealNearTop(chaptersCard, in: app)
        assertExists(app.staticTexts["The streak in the corner"], named: "seeded generated chapter")
        capture(iphone: "app_store_05_chapters", ipad: "app_store_05_chapters", in: app)

        if !isPad {
            openLibrary(in: app)
            assertExists(app.staticTexts["Greenhouse Hours"], named: "Greenhouse Hours library row")
            assertExists(app.staticTexts["Orbit Report"], named: "Orbit Report library row")
            assertExists(miniPlayer(in: app), named: "docked mini player on Library")
            attachAppStoreScreenshot(named: "app_store_08_library")

            openPrimaryPodcastDetail(in: app)
            openEpisodeDetailFromContextMenu(episodeID: Self.pipelineEpisodeID, in: app)
            let pipelineCard = element(withIdentifier: "Episode Pipeline Card", in: app)
            scrollUntilHittable(pipelineCard, in: app)
            assertExists(app.staticTexts["Making this episode ad-free"], named: "pipeline card title")
            assertExists(app.staticTexts["30:22 of 49:00"], named: "pipeline transcribe progress")
            attachAppStoreScreenshot(named: "app_store_06_pipeline")
        }

        performLibrarySearch(in: app)
        capture(iphone: "app_store_04_search", ipad: "app_store_04_search", in: app)

        // The mini player stays reachable under the search results, so the
        // Sound Lab closes the base launch and nothing after the search needs
        // the tab bar (the iPhone bar morphs into the search field; the iPad
        // bar hides outright).
        openNowPlayingFromMiniPlayer(in: app)
        revealNowPlayingSoundLab(in: app)
        assertExists(nowPlayingSoundLab(in: app), named: "Now Playing Sound Lab panel")
        assertSeededSkipZonesMarked(in: app)
        assertCompletedTranscriptReady(in: app)
        capture(iphone: "app_store_03_sound_lab", ipad: "app_store_06_sound_lab", in: app)

        if isPad {
            // A fresh launch keeps the grid free of the playback accessory.
            // The sidebar stays closed: in portrait it opens as an overlay
            // that dims the grid and hides the first column.
            app.launch()
            openLibrary(in: app)
            assertExists(app.staticTexts["Weeknight Notes"], named: "last library tile")
            attachAppStoreScreenshot(named: "app_store_02_library_grid")
        } else {
            // Up Next gets its own launch: the row context menus that fill the
            // queue drop the simulator's status-bar override for the rest of
            // the launch (the Up Next frame bleeds its status bar, the Sound
            // Lab frame does not), and tapping the primary row afterwards
            // opens Now Playing without any dismissal dance.
            app.launch()
            enqueueUpNextEpisodes(in: app)
            startPrimaryEpisodePlayback(in: app)
            openUpNextQueue(in: app)
            attachAppStoreScreenshot(named: "app_store_10_up_next")
        }

        app.launchEnvironment.removeValue(forKey: Self.queueOverrideEnvironmentKey)
        app.launchEnvironment.removeValue(forKey: Self.queueOverrideProgressEnvironmentKey)
        app.launchArguments.append(Self.autoSkipPillArgument)
        app.launch()
        startPrimaryEpisodePlayback(in: app)
        skipPlayback(into: 233...268, named: "just past the mid-roll zone", in: app)
        assertExists(app.descendants(matching: .any)["Skipped promo"], named: "pinned Skipped promo pill")
        capture(iphone: "app_store_01_skip", ipad: "app_store_01_skip", in: app)

        guard !isPad else {
            return
        }

        app.launchArguments.removeAll { $0 == Self.autoSkipPillArgument }
        app.launchArguments.append(Self.forceOnboardingArgument)
        app.launch()
        assertExists(
            app.staticTexts["Your listening is not a growth funnel."],
            named: "onboarding welcome pitch",
            timeout: 10
        )
        attachAppStoreScreenshot(named: "app_store_09_welcome")

        app.launchArguments.removeAll { $0 == Self.forceOnboardingArgument }
        try captureEpisodeNotificationScreenshot(app: app)
    }

    // Opt-in variants for the composition bakeoffs (run directly with
    // TEST_RUNNER_OPENCAST_SCREENSHOT_BAKEOFFS=1; the release lane never
    // selects this test). Captures land as raws named bakeoff_* which the
    // compositor spec ignores.
    @MainActor
    func testAppStoreScreenshotBakeoffs() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPENCAST_SCREENSHOT_BAKEOFFS"] == "1",
            "Set OPENCAST_SCREENSHOT_BAKEOFFS=1 to capture the bakeoff variants"
        )

        // Dark appearance: the three frames the plan names for the bakeoff.
        // The pinned pill overlaps the Now Playing title, so the hero gets
        // its own pinned launch after the unpinned chapters and library shots.
        let app = makeAppStoreScreenshotApp(appearanceArgument: "--opencast-force-dark-mode")
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        app.launch()
        startPrimaryEpisodePlayback(in: app)
        pausePlayback(in: app)
        openCurrentEpisodeDetailFromNowPlaying(in: app)
        let chaptersCard = element(withIdentifier: "Episode Chapters Card", in: app)
        scrollToRevealNearTop(chaptersCard, in: app)
        attachAppStoreScreenshot(named: "bakeoff_dark_05_chapters")
        openLibrary(in: app)
        assertExists(miniPlayer(in: app), named: "docked mini player (dark)")
        attachAppStoreScreenshot(named: "bakeoff_dark_08_library")

        app.launchArguments.append(Self.autoSkipPillArgument)
        app.launch()
        startPrimaryEpisodePlayback(in: app)
        skipPlayback(into: 233...268, named: "just past the mid-roll zone (dark)", in: app)
        assertExists(app.descendants(matching: .any)["Skipped promo"], named: "pinned Skipped promo pill (dark)")
        attachAppStoreScreenshot(named: "bakeoff_dark_01_skip")

        // Sound Lab pinned mid-slide.
        app.launchArguments.removeAll { $0 == Self.autoSkipPillArgument || $0 == "--opencast-force-dark-mode" }
        app.launchEnvironment.removeValue(forKey: "OPENCAST_FORCE_DARK_MODE")
        app.launchArguments.append("--opencast-force-light-mode")
        app.launchEnvironment["OPENCAST_PIN_APP_STORE_SOUND_LAB_REVEAL"] = "0.7"
        app.launch()
        startPrimaryEpisodePlayback(in: app)
        seekIntoSponsorRead(in: app)
        pausePlayback(in: app)
        assertExists(nowPlayingSoundLab(in: app), named: "pinned mid-slide Sound Lab panel")
        attachAppStoreScreenshot(named: "bakeoff_sound_lab_mid")

        // Ad Detection queue screen with one running and two pending items.
        app.launchEnvironment.removeValue(forKey: "OPENCAST_PIN_APP_STORE_SOUND_LAB_REVEAL")
        app.launchEnvironment[Self.queueOverrideEnvironmentKey] =
            "transcribing:\(Self.pipelineEpisodeID)|app-store-kitchen-table-episode-2|app-store-half-time-episode-2"
        app.launchEnvironment[Self.queueOverrideProgressEnvironmentKey] = "1822/2940"
        app.launch()
        openInbox(in: app)
        let indicator = app.buttons["Ad Detection Queue"].firstMatch
        assertHittable(indicator, named: "Inbox ad detection indicator")
        indicator.tap()
        assertExists(app.navigationBars["Ad Detection"], named: "Ad Detection queue screen")
        assertExists(app.staticTexts["The Quiet Season on the Sun"], named: "running queue row")
        attachAppStoreScreenshot(named: "bakeoff_queue_screen")
    }

    @MainActor
    private func makeAppStoreScreenshotApp(
        appearanceArgument: String = "--opencast-force-light-mode"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: false)
        // setupSnapshot appends the lane's cached launch arguments (including
        // its appearance flag); both appearance flags together resolve to the
        // system appearance, so only the requested one may remain.
        app.launchArguments.removeAll { $0 == "--opencast-force-light-mode" || $0 == "--opencast-force-dark-mode" }
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-app-store-screenshots",
            appearanceArgument,
            "-OPENCAST_REMOTE_TRANSCRIPTION_PURCHASE_FIXTURE",
            "review-screenshot"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_APP_STORE_SCREENSHOTS"] = "1"
        if appearanceArgument == "--opencast-force-light-mode" {
            app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        }
        return app
    }

    // MARK: - Notification

    // The notification is the shot's subject, so this capture path must not
    // use the banner-dismiss helper the app shots rely on. The app stays in
    // the foreground (the delegate presents banners there), so the card lands
    // over the Library instead of a Lock Screen with the simulator's fake
    // date. A long press afterwards captures the expanded rich card as a
    // bakeoff variant; if SpringBoard ignores it the banner shot stands.
    @MainActor
    private func captureEpisodeNotificationScreenshot(app: XCUIApplication) throws {
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Notification Permission") { alert in
            for buttonTitle in ["Allow", "Allow Notifications"] {
                let button = alert.buttons[buttonTitle]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments.append("--opencast-schedule-app-store-episode-notification")
        app.launchEnvironment["OPENCAST_SCHEDULE_APP_STORE_EPISODE_NOTIFICATION"] = "1"
        app.launch()

        // The permission alert is SpringBoard's; a tap into the app to trigger
        // the interruption monitor would land on an Inbox row instead.
        let allowButton = springboard.buttons["Allow"]
        if allowButton.waitForExistence(timeout: 3) {
            allowButton.tap()
        }
        openLibrary(in: app)
        assertExists(app.staticTexts["Greenhouse Hours"], named: "Library behind the notification")

        let banner = springboard.descendants(matching: .any)
            .matching(identifier: "NotificationShortLookView")
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "New-episode banner should appear over the app")
        assertExists(
            springboard.staticTexts["What the New Telescope Saw First"],
            named: "banner episode title",
            timeout: 3
        )
        // The banner is the fallback frame; the expanded rich card (artwork,
        // ORBIT REPORT, 49 MIN) replaces it under the same name when the long
        // press lands, so a failed expansion still leaves a valid shot.
        snapshot("app_store_07_notification", timeWaitingForIdle: 0)
        attachSmokeScreenshot(named: "bakeoff_notification_banner")

        banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        // "49 MIN" is rendered only by the content extension's expanded card.
        if springboard.staticTexts["49 MIN"].waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 1)
            snapshot("app_store_07_notification", timeWaitingForIdle: 0)
        }
        attachSmokeScreenshot(named: "app_store_07_notification")
    }

    // MARK: - Captures

    @MainActor
    private func capture(iphone: String, ipad: String, in app: XCUIApplication) {
        attachAppStoreScreenshot(named: isPad ? ipad : iphone)
    }

    @MainActor
    private func attachAppStoreScreenshot(named name: String) {
        dismissSystemNotificationBanners()
        snapshot(name, timeWaitingForIdle: 0)
        attachSmokeScreenshot(named: name)
    }

    @MainActor
    private func dismissSystemNotificationBanners() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let appleIntelligenceBanner = springboard.staticTexts["Ready for Apple Intelligence"]
        guard appleIntelligenceBanner.waitForExistence(timeout: 0.25) else {
            return
        }

        let start = appleIntelligenceBanner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = appleIntelligenceBanner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -4))
        start.press(forDuration: 0.05, thenDragTo: end)
        _ = appleIntelligenceBanner.waitForNonExistence(timeout: 1)
    }

    // MARK: - Playback

    // The primary episode is the newest row; after the Inbox has been
    // scrolled (Up Next enqueueing reaches its fourth-day rows) the lazy list
    // no longer holds it, so scroll back up until it does.
    @MainActor
    private func startPrimaryEpisodePlayback(in app: XCUIApplication) {
        openInbox(in: app)
        let primaryEpisode = episodeRow(Self.primaryEpisodeID, in: app)
        for _ in 0..<6 where !primaryEpisode.waitForExistence(timeout: 1) {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.8)
        }
        assertExists(primaryEpisode, named: "primary inbox episode")
        scrollUntilHittable(primaryEpisode, in: app)
        primaryEpisode.tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
    }

    /// Walks the playhead into `range` with the transport skip buttons (30s
    /// back, 15s forward), reading the elapsed label under the slider after
    /// every tap so a dropped tap or playback drift only costs another step.
    /// XCUI's slider adjust lands unpredictably on this slider and its
    /// accessibility value goes stale, so no shot relies on either.
    @MainActor
    private func skipPlayback(into range: ClosedRange<TimeInterval>, named name: String, in app: XCUIApplication) {
        var lastElapsed: TimeInterval?
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.8)
            guard let elapsed = elapsedSeconds(in: app) else {
                break
            }
            lastElapsed = elapsed
            if range.contains(elapsed) {
                return
            }
            tapTransportButton(elapsed > range.upperBound ? "Skip Back 30 Seconds" : "Skip Forward 15 Seconds", in: app)
        }
        XCTFail("Playhead should sit in \(name) (\(range)), got \(String(describing: lastElapsed))")
    }

    /// A skip-button landing inside an auto-skip zone is skipped past the
    /// zone's end, so the transport buttons alone can never park the playhead
    /// inside the sponsor read. The pill's undo is the one seek that lands
    /// inside a zone and plays it through: skip back into the read, let the
    /// auto-skip bounce, then undo it.
    @MainActor
    private func seekIntoSponsorRead(in app: XCUIApplication) {
        let range: ClosedRange<TimeInterval> = 28...55
        let pill = app.buttons["Skipped promo"].firstMatch
        var lastElapsed: TimeInterval?
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.6)
            guard let elapsed = elapsedSeconds(in: app) else {
                break
            }
            lastElapsed = elapsed
            if range.contains(elapsed) {
                return
            }
            tapTransportButton("Skip Back 30 Seconds", in: app)
            if pill.waitForExistence(timeout: 1.5) {
                pill.tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        XCTFail("Playhead should sit in the sponsor read (\(range)), got \(String(describing: lastElapsed))")
    }

    @MainActor
    private func tapTransportButton(_ label: String, in app: XCUIApplication) {
        let button = app.buttons[label].firstMatch
        assertHittable(button, named: label)
        button.tap()
    }

    // The elapsed label is the first m:ss text in the overlay; the remaining
    // label carries a leading minus and never matches.
    @MainActor
    private func elapsedSeconds(in app: XCUIApplication) -> TimeInterval? {
        let predicate = NSPredicate(format: "label MATCHES %@", "^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$")
        let label = nowPlayingOverlay(in: app).staticTexts.matching(predicate).firstMatch
        guard label.waitForExistence(timeout: 2) else {
            return nil
        }
        let parts = label.label.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3:
            return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        case 2:
            return parts[0] * 60 + parts[1]
        default:
            return nil
        }
    }

    @MainActor
    private func pausePlayback(in app: XCUIApplication) {
        let pauseButton = app.buttons["Pause"].firstMatch
        guard pauseButton.waitForExistence(timeout: 3) else {
            return
        }
        pauseButton.tap()
        _ = app.buttons["Play"].firstMatch.waitForExistence(timeout: 3)
    }

    @MainActor
    private func openNowPlayingFromMiniPlayer(in app: XCUIApplication) {
        let miniPlayer = miniPlayer(in: app)
        assertExists(miniPlayer, named: "mini player")
        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
    }

    @MainActor
    private func openUpNextQueue(in app: XCUIApplication) {
        let upNextButton = app.buttons["Up Next"].firstMatch
        assertExists(upNextButton, named: "Up Next utility button")
        upNextButton.tap()
        assertExists(app.navigationBars["Up Next"], named: "Up Next sheet")
        for episodeID in Self.upNextEpisodeIDs {
            assertExists(episodeRow(episodeID, in: app), named: "Up Next row \(episodeID)")
        }
    }

    // Play Last keeps the deck's order: the first enqueued row stays first.
    @MainActor
    private func enqueueUpNextEpisodes(in app: XCUIApplication) {
        openInbox(in: app)
        for episodeID in Self.upNextEpisodeIDs {
            let row = episodeRow(episodeID, in: app)
            scrollUntilHittable(row, in: app)
            row.press(forDuration: 1.2)
            let playLast = app.buttons["Play Last"].firstMatch
            assertExists(playLast, named: "Play Last context action for \(episodeID)")
            playLast.tap()
            _ = playLast.waitForNonExistence(timeout: 2)
        }
    }

    // MARK: - Navigation

    @MainActor
    private func openPrimaryPodcastDetail(in app: XCUIApplication) {
        openLibrary(in: app)
        let primaryPodcast = element(withIdentifier: Self.primarySubscriptionRowIdentifier, in: app)
        scrollUntilHittable(primaryPodcast, in: app)
        primaryPodcast.tap()
        assertExists(app.staticTexts["What the New Telescope Saw First"], named: "primary podcast episode")
    }

    // The Now Playing title opens the current episode's detail and dismisses
    // the card, so the primary episode never needs a row context menu.
    @MainActor
    private func openCurrentEpisodeDetailFromNowPlaying(in app: XCUIApplication) {
        let titleButton = nowPlayingOverlay(in: app).buttons["Now Playing Episode Title"].firstMatch
        assertHittable(titleButton, named: "Now Playing episode title button")
        titleButton.tap()
        assertExists(app.buttons["Play Episode"], named: "episode detail after tapping Now Playing title", timeout: 10)
    }

    // A long press that lands while the list is still settling opens nothing;
    // one retry covers that without hiding a genuinely missing menu.
    @MainActor
    private func openEpisodeDetailFromContextMenu(episodeID: String, in app: XCUIApplication) {
        let row = episodeRow(episodeID, in: app)
        scrollUntilHittable(row, in: app)
        let detailsAction = app.buttons["View Episode Details"].firstMatch
        for attempt in 0..<2 {
            row.press(forDuration: 1.3)
            if detailsAction.waitForExistence(timeout: 4) {
                break
            }
            XCTAssertEqual(attempt, 0, "View Episode Details context action should exist")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        detailsAction.tap()
        assertExists(app.buttons["Play Episode"], named: "episode detail Play button", timeout: 10)
    }

    @MainActor
    private func openTranscriptFromEpisodeDetail(in app: XCUIApplication) {
        let transcriptCard = element(withIdentifier: "Read Transcript", in: app)
        scrollUntilHittable(transcriptCard, in: app)
        transcriptCard.tap()
        assertExists(app.navigationBars["Transcript"], named: "Transcript screen", timeout: 10)
    }

    @MainActor
    private func performLibrarySearch(in app: XCUIApplication) {
        openSection("Search", in: app)
        let searchField = app.searchFields.firstMatch
        assertExists(searchField, named: "Search tab field")
        if !searchField.isHittable || app.keyboards.count == 0 {
            searchField.tap()
        }
        searchField.typeText("\(Self.searchQuery)\n")
        for episodeID in Self.searchResultEpisodeIDs {
            assertExists(episodeRow(episodeID, in: app), named: "search result \(episodeID)", timeout: 20)
        }
        _ = element(withIdentifier: "Search Index Updating", in: app).waitForNonExistence(timeout: 10)
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func tapBackButton(in app: XCUIApplication) {
        let backButton = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
        assertExists(backButton, named: "navigation back button")
        backButton.tap()
    }

    // MARK: - Scrolling

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxScrolls: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if element.waitForExistence(timeout: 1), isClearOfMiniPlayer(element, in: app) {
            return
        }

        for _ in 0..<maxScrolls {
            if element.exists, element.isHittable {
                nudgeAboveMiniPlayer(element, in: app)
                if isClearOfMiniPlayer(element, in: app) {
                    return
                }
            }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            if element.waitForExistence(timeout: 1), isClearOfMiniPlayer(element, in: app) {
                return
            }
        }

        XCTFail("Expected element to be hittable after scrolling", file: file, line: line)
    }

    // A row can report hittable while its lower half sits under the docked
    // mini player, and a long press there opens Now Playing instead.
    @MainActor
    private func isClearOfMiniPlayer(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.isHittable else {
            return false
        }
        let miniPlayer = miniPlayer(in: app)
        guard miniPlayer.exists else {
            return true
        }
        return element.frame.maxY <= miniPlayer.frame.minY - 4
    }

    @MainActor
    private func nudgeAboveMiniPlayer(_ element: XCUIElement, in app: XCUIApplication) {
        let miniPlayer = miniPlayer(in: app)
        guard miniPlayer.exists else {
            return
        }
        let overlap = element.frame.maxY - miniPlayer.frame.minY + 24
        guard overlap > 0 else {
            return
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let end = start.withOffset(CGVector(dx: 0, dy: -overlap))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Scrolls so `element`'s top edge sits near `targetYFraction` of the
    /// screen: a slow drag by the exact remaining distance, held briefly so
    /// no momentum carries the content past the target.
    @MainActor
    private func scrollToRevealNearTop(
        _ element: XCUIElement,
        in app: XCUIApplication,
        targetYFraction: CGFloat = 0.18
    ) {
        scrollUntilHittable(element, in: app)
        for _ in 0..<3 {
            let targetY = app.frame.height * targetYFraction
            let delta = element.frame.minY - targetY
            guard delta > 24 else {
                return
            }

            let startY = min(0.72, targetYFraction + delta / app.frame.height)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = start.withOffset(CGVector(dx: 0, dy: -min(delta, app.frame.height * 0.5)))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: - Assertions

    // Fails the lane loudly if the seeded analysis did not wire up as exactly
    // three auto-skip zones — the guard behind both the marked Now Playing
    // timeline and the Sound Lab shot.
    @MainActor
    private func assertSeededSkipZonesMarked(in app: XCUIApplication) {
        let control = app.descendants(matching: .any)["Skip Promos & Ads"].firstMatch
        assertExists(control, named: "Skip Promos & Ads control")
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "3 zones marked."),
            object: control
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Skip Promos & Ads control should report \"3 zones marked.\" from the seeded analysis, got \(String(describing: control.value))"
        )
    }

    @MainActor
    private func assertCompletedTranscriptReady(in app: XCUIApplication) {
        let control = app.descendants(matching: .any)["Show Transcript"].firstMatch
        assertExists(control, named: "Show Transcript control")
        XCTAssertTrue(control.isEnabled, "Show Transcript control should be ready to open")
    }

    @MainActor
    private func assertNowPlayingOverlay(in app: XCUIApplication) {
        assertExists(nowPlayingOverlay(in: app), named: "Now Playing overlay")
    }

    // MARK: - Now Playing gestures

    @MainActor
    private func revealNowPlayingSoundLab(in app: XCUIApplication) {
        let artwork = nowPlayingArtwork(in: app)
        assertExists(artwork, named: "Now Playing artwork before Sound Lab reveal")
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.52))
        let end = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.48))
        start.press(forDuration: 0.10, thenDragTo: end)
    }

    // MARK: - Elements

    @MainActor
    private func sponsorTranscriptRow(in app: XCUIApplication) -> XCUIElement {
        let sponsor = "Bottomless Mug Coffee Co."
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", sponsor, sponsor)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func element(withIdentifier identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func episodeRow(_ episodeID: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "episode-row-\(episodeID)").firstMatch
    }

    @MainActor
    private func miniPlayer(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Open Now Playing"].firstMatch
    }

    // Tabs keep their pushed stacks (episode detail opened from Now Playing
    // lands on the Inbox tab, podcast detail on Library), so every section
    // switch pops back to the root list before the next step.
    @MainActor
    private func openLibrary(in app: XCUIApplication) {
        openSectionRoot("Library", in: app)
    }

    @MainActor
    private func openInbox(in app: XCUIApplication) {
        openSectionRoot("Inbox", in: app)
    }

    @MainActor
    private func openSectionRoot(_ title: String, in app: XCUIApplication) {
        openSection(title, in: app)
        for _ in 0..<4 {
            if app.navigationBars[title].waitForExistence(timeout: 1) {
                return
            }
            let backButton = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            guard backButton.exists else {
                break
            }
            backButton.tap()
        }
        assertExists(app.navigationBars[title], named: "\(title) root screen", timeout: 3)
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
    private func nowPlayingSoundLab(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Now Playing Sound Lab"]
    }

    @MainActor
    private func playbackProgress(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Playback Progress"]
    }
}
