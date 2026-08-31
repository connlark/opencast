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

        let shareHeader = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "UI Test Show - Deterministic UI Episode")
        ).firstMatch
        assertExists(shareHeader, named: "activity sheet with sanitized share filename")
        attachSmokeScreenshot(named: "ipad_episode_diagnostics_share")
    }

    @MainActor
    private func makeSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-ui-library",
            "--opencast-force-dark-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
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
