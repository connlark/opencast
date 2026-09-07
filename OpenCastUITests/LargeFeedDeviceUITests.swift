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
        let count = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[0-9,]+ episodes.*")
        ).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 15), "The full catalog count must be visible")
        XCTAssertGreaterThanOrEqual(
            try episodeCount(from: count),
            13_753,
            "The live catalog must retain at least the pinned capture's history"
        )
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
        // Fixture publication can outlast navigation in a large existing
        // library. Wait while the header is still rendered before scrolling
        // past the location where the notice will appear.
        XCTAssertTrue(text.waitForExistence(timeout: 60))
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
        XCTAssertTrue(
            app.activityIndicators["Loading feed"].waitForExistence(timeout: 10),
            "The large live retry must be active before exercising row recycling"
        )

        // The regression trigger is specifically leaving the lazy header
        // while its retry runs. Scroll the notice out, open an episode detail,
        // and return; none of those view-lifetime changes may own cancellation.
        let episodeRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "episode-row-")
        )
        for _ in 0..<12 {
            if (!text.exists || !text.isHittable), episodeRows.allElementsBoundByIndex.contains(where: \.isHittable) {
                break
            }
            dragPodcast(in: app, towardHeader: false)
        }
        XCTAssertFalse(text.exists && text.isHittable, "The notice must actually leave the rendered viewport")
        attach(app, "Herd-retry-header-recycled")
        let episodeRow = try XCTUnwrap(episodeRows.allElementsBoundByIndex.first(where: \.isHittable))
        episodeRow.press(forDuration: 1.2)
        let viewDetails = app.buttons["View Episode Details"].firstMatch
        XCTAssertTrue(viewDetails.waitForExistence(timeout: 5))
        viewDetails.tap()
        XCTAssertTrue(app.buttons["Episode Actions"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Bring the lazy header back into consideration before waiting. A
        // nonexistence check while it remains recycled would pass even if the
        // incomplete state were still persisted.
        revealPodcastHeader(in: app)
        XCTAssertTrue(text.waitForNonExistence(timeout: 180), "A complete live retry must clear the persistent notice")
        app.terminate()
        app.launch()
        openSection("Library", in: app)
        XCTAssertTrue(herd.waitForExistence(timeout: 30))
        herd.tap()
        let count = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[0-9,]+ episodes.*")
        ).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10), "Partial import and retry must preserve the complete catalog")
        XCTAssertGreaterThanOrEqual(try episodeCount(from: count), 13_753)
        revealPodcastHeader(in: app)
        XCTAssertFalse(text.exists, "The cleared incomplete state must stay cleared after relaunch")
        attach(app, "Herd-partial-retry-recovered")
    }

    @MainActor
    private func revealPartialNotice(_ text: XCUIElement, in app: XCUIApplication) {
        revealPodcastHeader(in: app)
        for _ in 0..<6 {
            if text.exists && text.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
    }

    @MainActor
    private func revealPodcastHeader(in app: XCUIApplication) {
        // SwiftUI flattens the header's accessibility container when the
        // notice disappears. Its episode-count text exists in both states.
        let header = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[0-9,]+ episodes.*")
        ).firstMatch
        for _ in 0..<12 {
            if header.exists { break }
            // Pulling through the top opens the native podcast search. Close
            // it so absence of the header cannot masquerade as recovery.
            if app.searchFields.firstMatch.exists {
                app.navigationBars.buttons["Close"].tap()
            } else {
                dragPodcast(in: app, towardHeader: true)
            }
        }
        XCTAssertTrue(header.waitForExistence(timeout: 10), "The header must be rendered before checking its notice")
    }

    @MainActor
    private func dragPodcast(in app: XCUIApplication, towardHeader: Bool) {
        // Whole-app swipes start over the SE's mini-player. Keep both ends
        // inside the list viewport and hold the endpoint to stop momentum.
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        (towardHeader ? upper : lower).press(
            forDuration: 0.1,
            thenDragTo: towardHeader ? lower : upper,
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
    }

    private func elapsedSeconds(_ value: String) throws -> Double {
        let clock = try XCTUnwrap(value.components(separatedBy: " elapsed").first)
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        XCTAssertTrue((2...3).contains(parts.count), "Unexpected progress format: \(value)")
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func episodeCount(from element: XCUIElement) throws -> Int {
        let value = element.label.components(separatedBy: " episodes")[0]
            .replacingOccurrences(of: ",", with: "")
        return try XCTUnwrap(Int(value), "Unexpected episode-count label: \(element.label)")
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
