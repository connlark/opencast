import XCTest

/// Generate Chapters & Summary on the device: with a fixture key, through the
/// trial, with the trial used up, with a key the provider refuses, under an
/// armed or a refused background card, and a result saved by an earlier
/// version. The analysis transport is the app's fixture seam: no request
/// leaves the simulator and every key is a fixture.
final class ChaptersSummaryRouteUITests: XCTestCase {
    private static let seededEpisodeRowIdentifier = "episode-row-ui-test-episode-1"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGenerateWithFixtureKeyRendersBothCards() throws {
        let app = makeApp(seedsGoogleKey: true)
        app.launch()
        openSeededEpisodeDetail(in: app)

        tapGenerate(in: app)
        confirmDisclosure(in: app)

        assertGeneratedCards(in: app)
        attachSmokeScreenshot(named: "chapters_summary_generated_with_key")
        openEpisodeDiagnostics(in: app)
        assertDiagnosticsRow("Chapters & Summary · Route", "direct", in: app)
        assertDiagnosticsRow("Chapters & Summary · State", "finished", in: app)
    }

    @MainActor
    func testGenerateWithoutKeyRunsThroughTheTrial() throws {
        let app = makeApp(trialStatus: "units-left-3")
        app.launch()
        openSeededEpisodeDetail(in: app)

        tapGenerate(in: app)
        confirmDisclosure(in: app)

        assertGeneratedCards(in: app)
        openEpisodeDiagnostics(in: app)
        assertDiagnosticsRow("Chapters & Summary · Route", "trial", in: app)
    }

    @MainActor
    func testGenerateWithTrialUsedUpOpensTheKeyScreen() throws {
        let app = makeApp(trialStatus: "exhausted")
        app.launch()
        openSeededEpisodeDetail(in: app)

        tapGenerate(in: app)

        assertHittable(
            app.buttons["Analysis Key Required Open Settings"],
            named: "key screen from Generate",
            timeout: 10
        )
        assertDoesNotExist(
            app.staticTexts["Generate Chapters & Summary?"],
            named: "disclosure before the key screen"
        )
        attachSmokeScreenshot(named: "chapters_summary_key_required")
    }

    @MainActor
    func testRefusedKeyLeavesGenerateOfferedAndDiagnosticsShowsWhy() throws {
        let app = makeApp(seedsGoogleKey: true, transport: "invalid-key")
        app.launch()
        openSeededEpisodeDetail(in: app)

        tapGenerate(in: app)
        confirmDisclosure(in: app)

        // Fail-open: the card offers Generate again, never an error.
        let generate = app.buttons["Generate Chapters & Summary"]
        assertExists(generate, named: "Generate after a refused key", timeout: 20)
        assertDoesNotExist(app.descendants(matching: .any).matching(identifier: "Episode Chapters Card").firstMatch, named: "chapters card after a refused key")
        assertDoesNotExist(app.buttons["Analysis Key Required Open Settings"], named: "key screen for a refused key")

        openEpisodeDiagnostics(in: app)
        assertDiagnosticsRow("Failure Kind", "providerRejectedKey", in: app)
        assertDiagnosticsRow("Chapters & Summary · Listener Failure", "invalid_key", in: app)
    }

    @MainActor
    func testGenerateUnderAnArmedCardFinishesInTheBackground() throws {
        let app = makeApp(seedsGoogleKey: true, chaptersSession: "armed")
        app.launch()
        openSeededEpisodeDetail(in: app)

        tapGenerate(in: app)
        confirmDisclosure(in: app)

        assertGeneratedCards(in: app)
        openEpisodeDiagnostics(in: app)
        assertDiagnosticsRow("Chapters & Summary · Background", "Yes", in: app)
    }

    @MainActor
    func testGenerateWithTheCardRefusedRunsInTheForeground() throws {
        let app = makeApp(seedsGoogleKey: true, chaptersSession: "foreground-only")
        app.launch()
        openSeededEpisodeDetail(in: app)

        tapGenerate(in: app)
        confirmDisclosure(in: app)

        assertGeneratedCards(in: app)
        openEpisodeDiagnostics(in: app)
        assertDiagnosticsRow("Chapters & Summary · Background", "No", in: app)
    }

    @MainActor
    func testAResultSavedByAnEarlierVersionStillRenders() throws {
        let app = makeApp(seedsEarlierDocument: true)
        app.launch()
        openSeededEpisodeDetail(in: app)

        let chapters = app.descendants(matching: .any).matching(identifier: "Episode Chapters Card").firstMatch
        scrollUntilExists(chapters, in: app)
        assertExists(app.staticTexts["Seeded Welcome"], named: "earlier version's chapter title")
        assertExists(app.staticTexts["Summary"], named: "earlier version's summary card")
        assertDoesNotExist(app.buttons["Generate Chapters & Summary"], named: "Generate beside a current result")
    }

    // MARK: Launcher

    @MainActor
    private func makeApp(
        seedsGoogleKey: Bool = false,
        trialStatus: String? = nil,
        transport: String? = nil,
        chaptersSession: String? = nil,
        seedsEarlierDocument: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-ui-library",
            "--opencast-seed-completed-transcript",
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_SEED_COMPLETED_TRANSCRIPT"] = "1"
        if seedsGoogleKey {
            app.launchArguments.append("--opencast-seed-analysis-key-google")
        }
        if let trialStatus {
            app.launchArguments.append("--opencast-seed-analysis-trial=\(trialStatus)")
        }
        if let transport {
            app.launchArguments.append("--opencast-ui-test-analysis-transport=\(transport)")
        }
        if let chaptersSession {
            app.launchArguments.append("--opencast-ui-test-chapters-session=\(chaptersSession)")
        }
        if seedsEarlierDocument {
            app.launchEnvironment["OPENCAST_SEED_CHAPTERS_DOCUMENT"] = "1"
        }
        return app
    }

    // MARK: Steps

    @MainActor
    private func openSeededEpisodeDetail(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openSection("Inbox", in: app, file: file, line: line)
        let row = app.buttons.matching(identifier: Self.seededEpisodeRowIdentifier).firstMatch
        assertExists(row, named: "seeded inbox episode", timeout: 10, file: file, line: line)
        row.press(forDuration: 1.2)
        let details = app.buttons["View Episode Details"]
        assertExists(details, named: "View Episode Details context action", file: file, line: line)
        details.tap()
        assertExists(app.buttons["Episode Playback Control"], named: "seeded episode detail", timeout: 10, file: file, line: line)
    }

    @MainActor
    private func tapGenerate(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let generate = app.buttons["Generate Chapters & Summary"]
        scrollUntilExists(generate, in: app, file: file, line: line)
        // A coordinate tap: the glass button can swallow an element tap.
        generate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// The one-time disclosure, confirmed with its Generate button.
    @MainActor
    private func confirmDisclosure(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        assertExists(
            app.staticTexts["Generate Chapters & Summary?"],
            named: "generate disclosure",
            timeout: 10,
            file: file,
            line: line
        )
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Generate")).firstMatch
        assertHittable(confirm, named: "disclosure Generate", file: file, line: line)
        confirm.tap()
    }

    @MainActor
    private func assertGeneratedCards(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let chapters = app.descendants(matching: .any).matching(identifier: "Episode Chapters Card").firstMatch
        assertExists(chapters, named: "generated chapters card", timeout: 30, file: file, line: line)
        assertExists(app.staticTexts["Part One"], named: "fixture chapter title", file: file, line: line)
        assertExists(app.staticTexts["Summary"], named: "generated summary card", file: file, line: line)
        assertDoesNotExist(app.buttons["Generate Chapters & Summary"], named: "Generate after a result", file: file, line: line)
    }

    /// Opens Episode Diagnostics from the episode's actions menu.
    @MainActor
    private func openEpisodeDiagnostics(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let actions = app.buttons["Episode Actions"].firstMatch
        assertExists(actions, named: "Episode Actions menu", timeout: 10, file: file, line: line)
        actions.tap()
        let entry = app.buttons["Episode Diagnostics"].firstMatch
        assertExists(entry, named: "Episode Diagnostics entry", timeout: 10, file: file, line: line)
        entry.tap()
        assertExists(
            app.navigationBars["Episode Diagnostics"].firstMatch,
            named: "Episode Diagnostics sheet",
            timeout: 10,
            file: file,
            line: line
        )
    }

    /// A diagnostics row: LabeledContent rows read as one "Label, Value"
    /// text. Searches down the sheet, then back up.
    @MainActor
    private func assertDiagnosticsRow(
        _ label: String,
        _ value: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\(label), \(value)")).firstMatch
        for _ in 0..<30 where !(row.exists && row.isHittable) {
            app.swipeUp()
        }
        for _ in 0..<30 where !(row.exists && row.isHittable) {
            app.swipeDown()
        }
        assertExists(row, named: "diagnostics row \(label): \(value)", timeout: 2, file: file, line: line)
    }

    @MainActor
    private func scrollUntilExists(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        assertHittable(element, named: element.description, timeout: 10, file: file, line: line)
    }
}
