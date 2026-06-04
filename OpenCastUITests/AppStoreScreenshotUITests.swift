import XCTest

final class AppStoreScreenshotUITests: XCTestCase {
    private static let primaryFeedURL = "https://screenshots.opencast.example/signal-path.xml"
    private static let primaryEpisodeID = "app-store-signal-path-episode-1"
    private static let primaryEpisodeRowIdentifier = "episode-row-\(primaryEpisodeID)"
    private static let primarySubscriptionRowIdentifier = "subscription-row-\(primaryFeedURL)"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppStoreScreenshotSet() throws {
        let app = makeAppStoreScreenshotApp()
        app.launch()

        openLibrary(in: app)
        assertExists(app.staticTexts["Archive Hour"], named: "Archive Hour library row")
        assertExists(app.staticTexts["City Frequency"], named: "City Frequency library row")
        attachAppStoreScreenshot(named: "app_store_01_library")

        openInbox(in: app)
        assertExists(app.staticTexts["The Map Under the Morning Commute"], named: "filled inbox episode")
        let primaryEpisode = primaryEpisodeRow(in: app)
        assertExists(primaryEpisode, named: "primary inbox episode")
        attachAppStoreScreenshot(named: "app_store_02_inbox")

        openLibrary(in: app)
        let primaryPodcast = primarySubscriptionRow(in: app)
        scrollUntilHittable(primaryPodcast, in: app)
        primaryPodcast.tap()
        assertExists(app.staticTexts["Tracing the Bug That Only Appeared at Night"], named: "primary podcast episode")
        attachAppStoreScreenshot(named: "app_store_03_podcast_detail")

        openInbox(in: app)
        assertExists(primaryEpisode, named: "primary inbox episode")
        primaryEpisode.tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
        attachAppStoreScreenshot(named: "app_store_04_now_playing")

        peelNowPlayingArtwork(in: app)
        assertExists(nowPlayingSoundLab(in: app), named: "Now Playing Sound Lab panel")
        attachAppStoreScreenshot(named: "app_store_05_sound_lab")

        dismissNowPlayingOverlay(in: app)
        assertExists(app.buttons["Play Episode"], named: "Play Episode button")
        assertExists(app.staticTexts["Summary"], named: "episode summary")
        attachAppStoreScreenshot(named: "app_store_06_episode_detail")
    }

    @MainActor
    private func makeAppStoreScreenshotApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-app-store-screenshots",
            "--opencast-force-light-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_APP_STORE_SCREENSHOTS"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        return app
    }

    @MainActor
    private func attachAppStoreScreenshot(named name: String) {
        dismissSystemNotificationBanners()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
    private func openSection(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString,
        line: UInt
    ) {
        let tabButton = app.tabBars.buttons[title]
        if tabButton.waitForExistence(timeout: 1) {
            tabButton.tap()
            return
        }

        let sidebarButton = app.buttons[title]
        if sidebarButton.waitForExistence(timeout: 1) {
            sidebarButton.tap()
            return
        }

        let sidebarCell = app.cells.containing(.staticText, identifier: title).element
        if sidebarCell.waitForExistence(timeout: 1) {
            sidebarCell.tap()
            return
        }

        XCTFail("\(title) navigation item should exist", file: file, line: line)
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
    private func dismissNowPlayingOverlay(in app: XCUIApplication) {
        let overlay = nowPlayingOverlay(in: app)
        assertExists(overlay, named: "Now Playing overlay before dismissing")
        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.05, thenDragTo: end)
        assertDoesNotExist(nowPlayingOverlay(in: app), named: "Now Playing overlay after dismissing")
        assertExists(app.buttons["Open Now Playing"], named: "mini-player after dismissing Now Playing")
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
