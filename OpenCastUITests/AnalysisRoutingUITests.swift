import XCTest

/// Ad detection on the device by route: the listener's key, the free
/// analyses, or the key screen. Every analysis send is answered by the
/// app's fixture transport (the seeded sponsor line becomes one host-read
/// span), never the network; the seeded transcript lets Detect Ads go
/// straight to analysis. Keys here are fixtures, never real keys.
final class AnalysisRoutingUITests: XCTestCase {
    private static let transcriptEpisodeID = "ui-test-episode-1"
    private static let secondEpisodeID = "ui-test-episode-completed"
    private static let sponsorLine = "This row is brought to you by Seed Sponsor."
    private static let keyRequiredQueueNotice = "Add a key in Settings › AI Services to keep detecting ads"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Routes

    @MainActor
    func testDetectAdsWithAKeyRunsOnTheDeviceAndInstallsTheZone() throws {
        let app = makeApp(seedsGoogleKey: true)
        app.launch()

        detectAdsFromInbox(in: app)
        openEpisodeDetailFromInbox(in: app)
        assertAdsDetected(in: app)
        assertSponsorLineAnnotated(in: app)
        attachSmokeScreenshot(named: "analysis_route_direct_zone")

        // The run went to the listener's own provider: its usage counts it.
        assertUsage("google", contains: "Last run: 420 in · 36 out", in: app)
    }

    @MainActor
    func testDetectAdsWithoutAKeyRunsOnTheFreeAnalyses() throws {
        let app = makeApp(trialStatus: "units-left-3")
        app.launch()

        detectAdsFromInbox(in: app)
        openEpisodeDetailFromInbox(in: app)
        assertAdsDetected(in: app)
        assertSponsorLineAnnotated(in: app)

        // A free analysis is opencast's, not the listener's provider usage.
        assertUsage("google", contains: "No runs yet", in: app)
    }

    @MainActor
    func testNoKeyAndNoFreeAnalysesLeftOpensTheKeyScreenAndTheQueueSaysWhy() throws {
        // Each item waits 12 s before it starts, so the second episode joins
        // the same drain and parks at model consent, which keeps the queue
        // open after the first item ends.
        let app = makeApp(trialStatus: "exhausted", seedsSecondEpisode: true, launchHoldMilliseconds: 12_000)
        app.launch()

        openShow(in: app)
        detectAds(on: episodeRow(Self.transcriptEpisodeID, in: app), in: app)
        detectAds(on: episodeRow(Self.secondEpisodeID, in: app), in: app)

        let notNow = app.buttons["Analysis Key Required Not Now"]
        assertHittable(notNow, named: "key screen Not now", timeout: 30)
        assertExists(app.buttons["Analysis Key Required Open Settings"], named: "key screen Open Settings")
        assertExists(app.staticTexts["Add a key to keep going"], named: "key screen title")
        assertExists(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Your 5 free analyses are used.")
            ).firstMatch,
            named: "key screen body"
        )
        attachSmokeScreenshot(named: "analysis_route_key_screen")
        notNow.tap()
        assertDoesNotExist(notNow, named: "key screen after Not now", timeout: 5)

        openQueueScreenOnceParked(in: app)
        assertExists(app.staticTexts[Self.keyRequiredQueueNotice], named: "key-required banner", timeout: 10)
        let outcome = queueRow(Self.transcriptEpisodeID, in: app)
        assertExists(outcome, named: "key-required outcome row")
        XCTAssertTrue(
            outcome.label.contains("Your free analyses are used. Add a key in Settings › AI Services."),
            "The outcome row should name the reason, read \(outcome.label)"
        )
        attachSmokeScreenshot(named: "analysis_route_queue_key_required")
        // One item needed a key, so the key screen opened once.
        assertDoesNotExist(app.buttons["Analysis Key Required Not Now"], named: "a second key screen")
    }

    @MainActor
    func testRejectedKeyNamesTheProviderOnTheEpisodeCard() throws {
        let app = makeApp(seedsGoogleKey: true, transportAnswer: "invalid-key")
        app.launch()

        detectAdsFromInbox(in: app)
        openEpisodeDetailFromInbox(in: app)
        assertExists(app.staticTexts["Couldn't make this episode ad-free"], named: "failed pass card", timeout: 15)
        let detectStep = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Your provider didn't accept the key. Check it in Settings › AI Services.")
        ).firstMatch
        assertExists(detectStep, named: "rejected-key card copy")
        scrollUntilHittable(detectStep, in: app)
        attachSmokeScreenshot(named: "analysis_route_rejected_key_card")
        // A rejected key is the provider's answer; it never opens the key screen.
        assertDoesNotExist(app.buttons["Analysis Key Required Open Settings"], named: "key screen for a rejected key")
    }

    @MainActor
    func testSavedAnalysisRendersItsZoneWithoutARun() throws {
        // Any run would hold forever and count usage on the seeded key.
        let app = makeApp(seedsGoogleKey: true, holdsTransport: true, seedsCompletedAdAnalysis: true)
        app.launch()

        openEpisodeDetailFromInbox(in: app)
        assertAdsDetected(in: app)
        // A run would show the pass card (queued) or the detecting card
        // (foreground); a saved current analysis shows neither.
        assertDoesNotExist(app.staticTexts["Making this episode ad-free"], named: "pass card for a saved analysis")
        assertDoesNotExist(app.staticTexts["Detecting ads…"], named: "detecting card for a saved analysis")
        assertSponsorLineAnnotated(in: app)
        assertUsage("google", contains: "No runs yet", in: app)
    }

    // MARK: Launcher

    @MainActor
    private func makeApp(
        seedsGoogleKey: Bool = false,
        trialStatus: String? = nil,
        transportAnswer: String? = nil,
        holdsTransport: Bool = false,
        seedsCompletedAdAnalysis: Bool = false,
        seedsSecondEpisode: Bool = false,
        launchHoldMilliseconds: Int? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-dark-mode",
            "--opencast-seed-ui-library",
            "--opencast-seed-completed-transcript"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_SEED_COMPLETED_TRANSCRIPT"] = "1"
        // A stored mode skips the first-tap cloud-or-device dialog.
        app.launchEnvironment["OPENCAST_SEED_AD_DETECTION_MODE"] = "onDevice"
        if seedsGoogleKey {
            app.launchArguments.append("--opencast-seed-analysis-key-google")
        }
        if let trialStatus {
            app.launchArguments.append("--opencast-seed-analysis-trial=\(trialStatus)")
        }
        if let transportAnswer {
            app.launchArguments.append("--opencast-ui-test-analysis-transport=\(transportAnswer)")
        }
        if holdsTransport {
            app.launchArguments.append("--opencast-ui-test-analysis-transport-hold")
        }
        if seedsCompletedAdAnalysis {
            app.launchArguments.append("--opencast-seed-completed-ad-analysis")
            app.launchEnvironment["OPENCAST_SEED_COMPLETED_AD_ANALYSIS"] = "1"
        }
        if seedsSecondEpisode {
            // The episode-progress seed adds a played episode to the show.
            app.launchArguments.append("--opencast-seed-episode-progress")
            app.launchEnvironment["OPENCAST_SEED_EPISODE_PROGRESS"] = "1"
        }
        if let launchHoldMilliseconds {
            app.launchEnvironment["OPENCAST_UI_TEST_SOUND_LAB_LAUNCH_HOLD_MILLISECONDS"] = "\(launchHoldMilliseconds)"
        }
        return app
    }

    // MARK: Helpers

    @MainActor
    private func episodeRow(_ episodeID: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "episode-row-\(episodeID)").firstMatch
    }

    @MainActor
    private func queueRow(_ episodeID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ad-detection-queue-row-\(episodeID)").firstMatch
    }

    @MainActor
    private func detectAdsFromInbox(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openSection("Inbox", in: app, file: file, line: line)
        detectAds(on: episodeRow(Self.transcriptEpisodeID, in: app), in: app, file: file, line: line)
    }

    @MainActor
    private func detectAds(on row: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        scrollUntilHittable(row, in: app, file: file, line: line)
        row.press(forDuration: 1.2)
        let detect = app.buttons["Detect Ads"].firstMatch
        assertExists(detect, named: "Detect Ads context action", file: file, line: line)
        detect.tap()
        assertDoesNotExist(detect, named: "Detect Ads context action after the tap", timeout: 5, file: file, line: line)
    }

    /// The show's own list holds both seeded episodes; the Inbox only the
    /// unplayed one.
    @MainActor
    private func openShow(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openSection("Library", in: app, file: file, line: line)
        let show = app.descendants(matching: .any)
            .matching(identifier: "subscription-row-https://example.com/ui-test-feed.xml")
            .firstMatch
        assertExists(show, named: "seeded library show", timeout: 10, file: file, line: line)
        show.tap()
        assertExists(app.staticTexts["Episodes"], named: "show episodes", file: file, line: line)
    }

    @MainActor
    private func openEpisodeDetailFromInbox(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openSection("Inbox", in: app, file: file, line: line)
        let row = episodeRow(Self.transcriptEpisodeID, in: app)
        assertExists(row, named: "seeded inbox episode", timeout: 10, file: file, line: line)
        row.press(forDuration: 1.2)
        let details = app.buttons["View Episode Details"]
        assertExists(details, named: "View Episode Details context action", file: file, line: line)
        details.tap()
        assertExists(app.buttons["Episode Playback Control"], named: "seeded episode detail", timeout: 10, file: file, line: line)
    }

    /// Make Ad-Free reads "Ads detected" once a current analysis is saved.
    @MainActor
    private func assertAdsDetected(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let makeAdFree = app.buttons["Make Ad-Free"]
        assertExists(makeAdFree, named: "Make Ad-Free", file: file, line: line)
        let detected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Ads detected"),
            object: makeAdFree
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [detected], timeout: 20),
            .completed,
            "Make Ad-Free should read Ads detected, read \(makeAdFree.value as? String ?? "nil")",
            file: file,
            line: line
        )
    }

    /// From the episode detail: the transcript marks the sponsor line.
    @MainActor
    private func assertSponsorLineAnnotated(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let readTranscript = app.buttons["Read Transcript"]
        scrollUntilHittable(readTranscript, in: app, file: file, line: line)
        readTranscript.tap()
        assertExists(app.staticTexts["Transcript"], named: "Transcript title", file: file, line: line)
        let annotated = app.buttons.matching(NSPredicate(
            format: "label == %@ AND value CONTAINS %@",
            Self.sponsorLine,
            "Sponsor segment"
        )).firstMatch
        assertExists(annotated, named: "sponsor line marked as a sponsor segment", timeout: 10, file: file, line: line)
    }

    @MainActor
    private func assertUsage(
        _ provider: String,
        contains text: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openSettingsScreen("AI Services", in: app, file: file, line: line)
        let usage = app.descendants(matching: .any)["AI Services Usage \(provider)"].firstMatch
        scrollUntilHittable(usage, in: app, maxSwipes: 8, file: file, line: line)
        XCTAssertTrue(
            usage.label.contains(text),
            "The \(provider) usage row should read \(text), read \(usage.label)",
            file: file,
            line: line
        )
    }

    /// Opens the queue screen from the Inbox indicator and waits there until
    /// the second item has parked at model consent. The indicator's value
    /// never reaches XCUI from the toolbar, so the screen itself says when.
    @MainActor
    private func openQueueScreenOnceParked(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openSection("Inbox", in: app, file: file, line: line)
        let indicator = app.buttons["Ad Detection Queue Indicator"]
        let queueScreen = app.navigationBars["Ad Detection"]
        assertExists(indicator, named: "queue indicator", timeout: 10, file: file, line: line)
        for _ in 0..<3 where !queueScreen.exists {
            if indicator.exists {
                indicator.tap()
            }
            _ = queueScreen.waitForExistence(timeout: 3)
        }
        assertExists(queueScreen, named: "queue screen", file: file, line: line)
        let consent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Download Model")).firstMatch
        assertExists(consent, named: "model consent affordance of the parked item", timeout: 60, file: file, line: line)
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }
}
