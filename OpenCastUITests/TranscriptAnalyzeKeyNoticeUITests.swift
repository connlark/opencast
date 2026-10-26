import XCTest

/// Analyze Promos & Ads from the transcript's menu waits behind the one-time
/// key notice like every other analysis start: Later runs the held analysis
/// once, and the notice never shows again. With no key saved the analysis
/// runs on the free analyses through the app's fixture transport; no request
/// leaves the simulator.
final class TranscriptAnalyzeKeyNoticeUITests: XCTestCase {
    private static let seededEpisodeRowIdentifier = "episode-row-ui-test-episode-1"
    private static let sponsorLine = "This row is brought to you by Seed Sponsor."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAnalyzeFromTheTranscriptMenuWaitsForTheKeyNotice() throws {
        let app = makeApp()
        app.launch()
        openSeededTranscript(in: app)

        openTranscriptOptions(in: app)
        let analyze = app.buttons["Analyze Promos & Ads"]
        assertExists(analyze, named: "Analyze Promos & Ads", timeout: 5)
        analyze.tap()

        let later = app.buttons["AI Key Notice Later"]
        assertHittable(later, named: "notice Later button", timeout: 10)
        assertExists(app.buttons["AI Key Notice Add Key"], named: "notice Add a key button")
        attachSmokeScreenshot(named: "transcript_analyze_key_notice")
        later.tap()
        assertDoesNotExist(later, named: "notice after Later", timeout: 5)

        // Later ran the held analysis: the sponsor line is marked.
        let annotated = app.buttons.matching(NSPredicate(
            format: "label == %@ AND value CONTAINS %@",
            Self.sponsorLine,
            "Sponsor segment"
        )).firstMatch
        assertExists(annotated, named: "sponsor line marked after Later", timeout: 30)

        // The notice shows once: the next analysis starts at once.
        openTranscriptOptions(in: app)
        let reanalyze = app.buttons["Reanalyze Promos & Ads"]
        assertExists(reanalyze, named: "Reanalyze Promos & Ads", timeout: 5)
        reanalyze.tap()
        assertDoesNotExist(app.buttons["AI Key Notice Later"], named: "notice on the second analysis", timeout: 3)
    }

    // MARK: Launcher

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-ui-library",
            "--opencast-seed-completed-transcript",
            "--opencast-seed-analysis-trial=units-left-3",
            "--opencast-force-analysis-key-notice",
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_SEED_COMPLETED_TRANSCRIPT"] = "1"
        // A stored mode skips the first-tap cloud-or-device dialog.
        app.launchEnvironment["OPENCAST_SEED_AD_DETECTION_MODE"] = "onDevice"
        return app
    }

    // MARK: Steps

    @MainActor
    private func openSeededTranscript(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openSection("Inbox", in: app, file: file, line: line)
        let row = app.buttons.matching(identifier: Self.seededEpisodeRowIdentifier).firstMatch
        assertExists(row, named: "seeded inbox episode", timeout: 10, file: file, line: line)
        row.press(forDuration: 1.2)
        let details = app.buttons["View Episode Details"]
        assertExists(details, named: "View Episode Details context action", file: file, line: line)
        details.tap()
        let readTranscript = app.buttons["Read Transcript"]
        for _ in 0..<8 where !(readTranscript.exists && readTranscript.isHittable) {
            app.swipeUp()
        }
        assertHittable(readTranscript, named: "Read Transcript", timeout: 10, file: file, line: line)
        readTranscript.tap()
        assertExists(app.staticTexts["Transcript"], named: "Transcript title", timeout: 10, file: file, line: line)
    }

    @MainActor
    private func openTranscriptOptions(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let menuButton = app.buttons["Transcript Options"]
        assertExists(menuButton, named: "Transcript Options menu button", timeout: 10, file: file, line: line)
        menuButton.tap()
    }
}
