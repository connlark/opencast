import XCTest

/// Release device checks for live RSS addition and the persistent pinned Herd
/// catalog imported by FeedBenchmarkRunner.
final class LargeFeedDeviceUITests: XCTestCase {
    private static let largeFeedURLKey = "OPENCAST_LARGE_FEED_URL"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENCAST_LARGE_FEED_DEVICE_QA"] == "1",
                          "Opt in with TEST_RUNNER_OPENCAST_LARGE_FEED_DEVICE_QA=1 on a physical device")
        continueAfterFailure = false
    }

    @MainActor
    func testLiveHerdDirectRSSAdditionShowsCompleteCatalog() throws {
        let feedURL = try Self.largeFeedURLOrSkip()
        let app = XCUIApplication()
        // Fresh local test storage exercises the actual add flow without
        // deleting the device's persistent subscriptions or playback progress.
        app.launchArguments = ["--opencast-ui-testing"]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = feedURL
        app.launch()
        openSection("Library", in: app)
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        let subscribe = app.buttons["Subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 10))
        subscribe.tap()
        XCTAssertTrue(app.activityIndicators["Subscribing"].waitForExistence(timeout: 10))
        let herd = app.staticTexts["The Herd with Colin Cowherd"].firstMatch
        XCTAssertTrue(herd.waitForExistence(timeout: 360))
        herd.tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9,]+ episodes.*")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        let value = count.label.components(separatedBy: " episodes")[0].replacingOccurrences(of: ",", with: "")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(Int(value)), 13_753,
                                    "The live catalog must include at least the pinned capture's history")
        XCTAssertFalse(app.staticTexts["Some episodes couldn’t be loaded. Available episodes are ready to play."].exists)
        attach(app, "Herd-live-RSS-addition")
    }

    @MainActor
    func testHerdCompleteHistoryNotesPlaybackAndResume() throws {
        let app = XCUIApplication()
        app.launch()
        if app.staticTexts["Welcome to opencast!"].waitForExistence(timeout: 8) {
            for title in ["Continue", "Skip", "Continue", "Skip", "Done"] {
                let button = app.buttons[title].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 10))
                button.tap()
            }
        }
        openSection("Library", in: app)
        let herd = app.staticTexts["The Herd with Colin Cowherd"].firstMatch
        XCTAssertTrue(herd.waitForExistence(timeout: 30))
        herd.tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "13,753 episodes", "13753 episodes")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 15), "The pinned full catalog count must be visible")
        attach(app, "Herd-full-catalog")

        app.buttons["Podcast Actions"].tap()
        app.buttons["Search"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Todd Gurley, Le'Veon Bell & Dumpster Fire-Archy\n")
        let oldest = app.buttons["episode-row-dc4e701da76eb30533952f9b4c90ceb1859cc84676c45f1ba4b70540082655e0"]
        XCTAssertTrue(oldest.waitForExistence(timeout: 30), "Database search must find the oldest supplied episode")
        oldest.tap()
        let overlay = app.descendants(matching: .any)["Now Playing"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 20))
        let pause = overlay.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 45), "The old MP3 must actually enter playback")
        let progress = app.descendants(matching: .any)["Playback Progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        let before = progress.value as? String
        RunLoop.current.run(until: Date.now.addingTimeInterval(3))
        XCTAssertNotEqual(progress.value as? String, before, "Audio position must advance")
        pause.tap()
        XCTAssertTrue(overlay.buttons["Play"].firstMatch.waitForExistence(timeout: 10))
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        let savedProgress = try XCTUnwrap(progress.value as? String)
        XCTAssertFalse(savedProgress.hasPrefix("0:00 elapsed"))
        attach(app, "Herd-old-episode-seek")

        overlay.buttons["Now Playing Episode Title"].firstMatch.tap()
        let fullNotes = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "David Spade")).firstMatch
        for _ in 0..<5 where !fullNotes.isHittable { app.swipeUp() }
        XCTAssertTrue(fullNotes.waitForExistence(timeout: 15), "Complete publisher notes must load on demand")
        attach(app, "Herd-old-episode-notes")

        app.terminate()
        app.launch()
        let miniPlayer = app.buttons["Open Now Playing"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30))
        miniPlayer.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        let restoredProgress = try XCTUnwrap(progress.value as? String)
        let savedSeconds = try elapsedSeconds(savedProgress)
        let restoredSeconds = try elapsedSeconds(restoredProgress)
        // The existing smart-resume policy rewinds three seconds within an
        // hour. Publisher-inserted ads may also change the remaining duration.
        XCTAssertEqual(restoredSeconds, savedSeconds - 3, accuracy: 2, "Saved position must survive relaunch with smart resume")
        overlay.buttons["Play"].firstMatch.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        overlay.buttons["Now Playing Podcast Title"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Podcast Actions"].waitForExistence(timeout: 15))
        app.buttons["Podcast Actions"].tap()
        app.buttons["Refresh"].firstMatch.tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 10))
        miniPlayer.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "Feed refresh must leave playback usable")
        pause.tap()
        XCTAssertTrue(overlay.buttons["Play"].firstMatch.waitForExistence(timeout: 10))
        attach(app, "Herd-refresh-playback-controls")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHerdPartialNoticeRetryPreservesHistory() throws {
        let feedURL = try Self.largeFeedURLOrSkip()
        let app = XCUIApplication()
        app.launchArguments = [
            "--opencast-run-feed-benchmark", "--opencast-feed-benchmark-file", "herd-partial.xml",
            "--opencast-feed-benchmark-label", "herd-partial-ui",
            "--opencast-feed-benchmark-url",
            feedURL
        ]
        app.launch()
        openSection("Library", in: app)
        let herd = app.staticTexts["The Herd with Colin Cowherd"].firstMatch
        XCTAssertTrue(herd.waitForExistence(timeout: 30))
        herd.tap()
        let text = app.staticTexts["Some episodes couldn’t be loaded. Available episodes are ready to play."]
        revealPartialNotice(text, in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        attach(app, "Herd-partial-notice")
        // Reopen without importing again to prove that the notice is persistent.
        app.terminate()
        app.launchArguments = []
        app.launch()
        openSection("Library", in: app)
        XCTAssertTrue(herd.waitForExistence(timeout: 30))
        herd.tap()
        revealPartialNotice(text, in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        app.buttons["Retry"].firstMatch.tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 120), "A complete live retry must clear the persistent notice")
        app.terminate()
        app.launch()
        openSection("Library", in: app)
        XCTAssertTrue(herd.waitForExistence(timeout: 30))
        herd.tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "13,753 episodes", "13753 episodes")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10), "Partial import and retry must preserve the complete catalog")
        attach(app, "Herd-partial-retry-recovered")
    }

    @MainActor
    private func revealPartialNotice(_ text: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !text.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
    }

    private func elapsedSeconds(_ value: String) throws -> Double {
        let clock = try XCTUnwrap(value.components(separatedBy: " elapsed").first)
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        XCTAssertTrue((2...3).contains(parts.count), "Unexpected progress format: \(value)")
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func largeFeedURLOrSkip() throws -> String {
        guard let feedURL = ProcessInfo.processInfo.environment[largeFeedURLKey],
              !feedURL.isEmpty
        else {
            throw XCTSkip("Set \(largeFeedURLKey) to the expected public large-feed RSS URL before running this proof.")
        }

        return feedURL
    }
}
