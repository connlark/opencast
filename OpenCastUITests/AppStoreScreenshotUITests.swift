import XCTest

final class AppStoreScreenshotUITests: XCTestCase {
    private static let primaryFeedURL = "https://screenshots.opencast.example/signal-path.xml"
    private static let primaryEpisodeID = "app-store-signal-path-episode-1"
    private static let primaryEpisodeRowIdentifier = "episode-row-\(primaryEpisodeID)"
    private static let primarySubscriptionRowIdentifier = "subscription-row-\(primaryFeedURL)"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Capture order differs from App Store order: the transcript is captured
    // before playback starts (follow-along would scroll the sponsor badge out
    // of the first screenful once the episode is the current one), and the
    // notification is captured last so its banner cannot contaminate the
    // other shots.
    @MainActor
    func testAppStoreScreenshotSet() throws {
        let app = makeAppStoreScreenshotApp()
        app.launch()

        openLibrary(in: app)
        assertExists(app.staticTexts["Archive Hour"], named: "Archive Hour library row")
        assertExists(app.staticTexts["City Frequency"], named: "City Frequency library row")
        attachAppStoreScreenshot(named: "app_store_04_library")

        openInbox(in: app)
        assertExists(app.staticTexts["The Map Under the Morning Commute"], named: "filled inbox episode")
        let primaryEpisode = primaryEpisodeRow(in: app)
        assertExists(primaryEpisode, named: "primary inbox episode")
        attachAppStoreScreenshot(named: "app_store_07_inbox")

        openLibrary(in: app)
        let primaryPodcast = primarySubscriptionRow(in: app)
        scrollUntilHittable(primaryPodcast, in: app)
        primaryPodcast.tap()
        assertExists(app.staticTexts["Tracing the Bug That Only Appeared at Night"], named: "primary podcast episode")
        attachAppStoreScreenshot(named: "app_store_05_podcast_detail")

        openPrimaryEpisodeDetailFromContextMenu(in: app)
        assertExists(adSpanTimelineCaption(in: app), named: "seeded ad-span timeline caption")
        attachAppStoreScreenshot(named: "app_store_08_episode_detail")

        openTranscriptFromEpisodeDetail(in: app)
        assertExists(sponsorTranscriptRow(in: app), named: "Bottomless Mug sponsor transcript row", timeout: 10)
        attachAppStoreScreenshot(named: "app_store_02_transcript")

        openInbox(in: app)
        assertExists(primaryEpisode, named: "primary inbox episode before playback")
        primaryEpisode.tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        attachAppStoreScreenshot(named: "app_store_01_now_playing")

        revealNowPlayingSoundLab(in: app)
        assertExists(nowPlayingSoundLab(in: app), named: "Now Playing Sound Lab panel")
        assertSeededSkipZonesMarked(in: app)
        assertCompletedTranscriptReady(in: app)
        attachAppStoreScreenshot(named: "app_store_06_sound_lab")

        try captureCompletionNotificationScreenshot(app: app)
    }

    @MainActor
    private func makeAppStoreScreenshotApp() -> XCUIApplication {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: false)
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-app-store-screenshots",
            "--opencast-force-light-mode",
            "-OPENCAST_REMOTE_TRANSCRIPTION_PURCHASE_FIXTURE",
            "review-screenshot"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_APP_STORE_SCREENSHOTS"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        return app
    }

    // The completion notification is the shot's subject, so this capture path
    // must not use the banner-dismiss helper the app shots rely on.
    @MainActor
    private func captureCompletionNotificationScreenshot(app: XCUIApplication) throws {
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
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        settleSpringBoardNotificationSurface(in: springboard)
        clearAllSpringBoardNotifications(in: springboard)

        app.launchArguments.append("--opencast-schedule-app-store-adfreepass-notification")
        app.launchEnvironment["OPENCAST_SCHEDULE_APP_STORE_ADFREEPASS_NOTIFICATION"] = "1"
        app.launch()
        app.tap()

        let allowButton = springboard.buttons["Allow"]
        if allowButton.waitForExistence(timeout: 5) {
            allowButton.tap()
        }

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        settleSpringBoardNotificationSurface(in: springboard)
        let notification = try waitForSpringBoardNotification(
            containing: "ad breaks",
            in: springboard,
            timeout: 30
        )
        XCTAssertTrue(notification.exists, "Completion notification should be on SpringBoard for capture")
        snapshot("app_store_03_notification", timeWaitingForIdle: 0)
        attachSmokeScreenshot(named: "app_store_03_notification")
    }

    // Freshly created simulators post system notifications ("Ready for Apple
    // Intelligence") that would share the shot with the fixture card. This
    // runs before the fixture is scheduled, so it can safely swipe-clear
    // every labeled notification cell it finds.
    @MainActor
    private func clearAllSpringBoardNotifications(in springboard: XCUIApplication) {
        let cellPredicate = NSPredicate(
            format: "(identifier == %@ OR identifier == %@) AND label != %@",
            "ListCell",
            "NotificationShortLookView",
            ""
        )
        for _ in 0..<4 {
            let cell = springboard.descendants(matching: .any).matching(cellPredicate).firstMatch
            guard cell.waitForExistence(timeout: 1) else {
                return
            }

            cell.swipeLeft()
            let clearButton = springboard.buttons["Clear"].firstMatch
            guard clearButton.waitForExistence(timeout: 2) else {
                return
            }
            clearButton.tap()
            Thread.sleep(forTimeInterval: 1)
        }
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

    @MainActor
    private func openPrimaryEpisodeDetailFromContextMenu(in app: XCUIApplication) {
        let row = primaryEpisodeRow(in: app)
        assertExists(row, named: "primary episode row in podcast detail")
        row.press(forDuration: 1.2)

        let detailsAction = app.buttons["View Episode Details"].firstMatch
        assertExists(detailsAction, named: "View Episode Details context action")
        detailsAction.tap()
        assertExists(app.buttons["Play Episode"], named: "episode detail Play button", timeout: 10)
    }

    @MainActor
    private func openTranscriptFromEpisodeDetail(in app: XCUIApplication) {
        let transcriptCard = app.descendants(matching: .any)
            .matching(identifier: "Read Transcript")
            .firstMatch
        scrollUntilHittable(transcriptCard, in: app)
        transcriptCard.tap()
        assertExists(app.navigationBars["Transcript"], named: "Transcript screen", timeout: 10)
    }

    @MainActor
    private func sponsorTranscriptRow(in app: XCUIApplication) -> XCUIElement {
        let sponsor = "Bottomless Mug Coffee Co."
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", sponsor, sponsor)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func adSpanTimelineCaption(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", "4 ad segments")
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    // Fails the lane loudly if the seeded analysis did not wire up as exactly
    // three auto-skip zones — the guard behind both the marked Now Playing
    // timeline and this Sound Lab shot.
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
    private func primarySubscriptionRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.primarySubscriptionRowIdentifier).firstMatch
    }

    @MainActor
    private func primaryEpisodeRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Self.primaryEpisodeRowIdentifier).firstMatch
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
    private func openInbox(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openSection("Inbox", in: app, file: file, line: line)
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxScrolls: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if element.waitForExistence(timeout: 1), element.isHittable {
            return
        }

        for _ in 0..<maxScrolls {
            app.swipeUp()
            if element.waitForExistence(timeout: 1), element.isHittable {
                return
            }
        }

        XCTFail("Expected element to be hittable after scrolling", file: file, line: line)
    }

    @MainActor
    private func assertNowPlayingOverlay(in app: XCUIApplication) {
        assertExists(nowPlayingOverlay(in: app), named: "Now Playing overlay")
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
