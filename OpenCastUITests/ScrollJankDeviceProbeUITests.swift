import XCTest

/// On-device scroll-jank measurement for
/// `notes/bugs/2026-07-22-scroll-jank-active-download.md`. Launches the real
/// app (no seeding seams, real store) with the frame-pacing probe enabled,
/// drives the same Inbox scroll workload under increasing load — restored
/// baseline, active download, on-device ad detection, playback — and prints
/// each scenario's frame-gap histogram as `SCROLLPROBE[...]` lines plus
/// attachments.
///
/// Opt-in via `TEST_RUNNER_OPENCAST_SCROLL_PROBE=1`; skips everywhere else so
/// regression lanes are unaffected. Scenarios are cumulative by design: the
/// download from scenario B may still be running during C and D, matching the
/// real-world report ("active download + queue + playback").
final class ScrollJankDeviceProbeUITests: XCTestCase {
    private static let optInEnvironmentKey = "OPENCAST_SCROLL_PROBE"
    private static let flushSettleSeconds: UInt32 = 3

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1",
            "scroll probe is opt-in; set TEST_RUNNER_OPENCAST_SCROLL_PROBE=1"
        )
        continueAfterFailure = true
    }

    @MainActor
    func testInboxScrollFramePacingAcrossLoadScenarios() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--opencast-frame-probe")
        app.launch()

        openSection("Inbox", in: app)
        sleep(2)

        XCTAssertTrue(
            app.buttons["Probe Mark"].waitForExistence(timeout: 10),
            "Probe Mark button must be reachable — frame probe not enabled or button occluded"
        )

        var sessionsSeen = 0
        sessionsSeen = runScrollScenario("baseline-restored-state", app: app, previousSessions: sessionsSeen)

        let downloadStarted = startContextMenuAction(
            "Download",
            onEpisodeTitled: Self.downloadEpisodeTitle,
            app: app
        )
        if downloadStarted {
            sessionsSeen = runScrollScenario("download-burst", app: app, previousSessions: sessionsSeen)
        } else {
            print("SCROLLPROBE[download-burst]: SKIPPED — no enabled Download action found")
        }

        let detectionStarted = startAdDetection(onEpisodeTitled: Self.detectAdsEpisodeTitle, app: app)
        if detectionStarted {
            sleep(10)
            sessionsSeen = runScrollScenario("ad-detection-active", app: app, previousSessions: sessionsSeen)
        } else {
            print("SCROLLPROBE[ad-detection-active]: SKIPPED — no enabled Detect Ads action found")
        }

        startPlayback(ofEpisodeTitled: Self.playbackEpisodeTitle, app: app)
        let compoundDownloadStarted = startContextMenuAction(
            "Download",
            onEpisodeTitled: Self.compoundDownloadEpisodeTitle,
            app: app
        )
        let compoundLabel = compoundDownloadStarted
            ? "compound-play-transcribe-download"
            : "compound-play-transcribe"
        sessionsSeen = runScrollScenario(compoundLabel, app: app, previousSessions: sessionsSeen)

        let fullSummary = frameSummaryValue(in: app)
        attach(fullSummary, named: "ScrollProbe-AllSessions")
        print("SCROLLPROBE[all-sessions]: \(fullSummary)")
        XCTAssertTrue(fullSummary.contains("session="), "expected at least one probe session, got: \(fullSummary)")
    }

    // MARK: - Scenario driving

    @MainActor
    private func runScrollScenario(
        _ label: String,
        app: XCUIApplication,
        previousSessions: Int
    ) -> Int {
        let scrollTarget = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app
        tapProbeMark(app)
        for _ in 0..<3 {
            scrollTarget.swipeUp(velocity: .fast)
            tapProbeMark(app)
            scrollTarget.swipeDown(velocity: .fast)
            tapProbeMark(app)
        }
        attachScreenshot(of: app, named: "State-\(label)")
        sleep(Self.flushSettleSeconds)

        let value = frameSummaryValue(in: app)
        let sessions = value.components(separatedBy: " || ").filter { $0.contains("session=") }
        let newSessions = sessions.count > previousSessions
            ? Array(sessions[previousSessions...])
            : []
        let scenarioSummary = newSessions.isEmpty
            ? "NO NEW SESSIONS (probe idle or marks missing) — total value: \(value)"
            : newSessions.joined(separator: " || ")
        attach(scenarioSummary, named: "ScrollProbe-\(label)")
        print("SCROLLPROBE[\(label)]: \(scenarioSummary)")
        return sessions.count
    }

    @MainActor
    private func frameSummaryValue(in app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["Frame Pacing Summary"]
        guard element.waitForExistence(timeout: 10) else {
            return "frame probe element missing"
        }
        return (element.value as? String) ?? ""
    }

    // MARK: - Load-state arrangement

    /// Long real episodes from Connor's live library, all reachable within the
    /// first screens of the Inbox (search targeting proved flaky on device).
    /// Downloads finish in ~5s on Connor's Wi-Fi (160MB SN episodes measured at
    /// ~32MB/s), so download scenarios scroll IMMEDIATELY after the tap to
    /// catch the burst; the sustained load comes from on-device transcription.
    ///
    /// Downloads and detections are sticky on-device (Download disappears once
    /// completed; Detect Ads becomes "Ads Detected" and disables), so repeat
    /// runs override the targets with fresh episodes via
    /// `TEST_RUNNER_OPENCAST_SCROLL_PROBE_{DOWNLOAD,DETECT,PLAY,DOWNLOAD2}`.
    private static func episodeTitle(_ environmentKey: String, default defaultTitle: String) -> String {
        let value = ProcessInfo.processInfo.environment["OPENCAST_SCROLL_PROBE_\(environmentKey)"]
        return value?.isEmpty == false ? value! : defaultTitle
    }

    private static var downloadEpisodeTitle: String { episodeTitle("DOWNLOAD", default: "SN 1087") }
    private static var detectAdsEpisodeTitle: String { episodeTitle("DETECT", default: "Iraqi Insurgency") }
    private static var playbackEpisodeTitle: String { episodeTitle("PLAY", default: "World Cup") }
    private static var compoundDownloadEpisodeTitle: String { episodeTitle("DOWNLOAD2", default: "SN 1086") }

    @MainActor
    private func startAdDetection(onEpisodeTitled title: String, app: XCUIApplication) -> Bool {
        guard startContextMenuAction("Detect Ads", onEpisodeTitled: title, app: app) else {
            return false
        }

        let onDevice = app.buttons["Detect On This Device"]
        if onDevice.waitForExistence(timeout: 4) {
            onDevice.tap()
        }
        return true
    }

    @MainActor
    private func startPlayback(ofEpisodeTitled title: String, app: XCUIApplication) {
        guard let row = findInboxRow(containing: title, in: app) else {
            print("SCROLLPROBE[playing]: no inbox row for \(title)")
            return
        }

        row.tap()
        sleep(2)
        dismissNowPlayingIfPresented(app)
    }

    @MainActor
    private func startContextMenuAction(
        _ action: String,
        onEpisodeTitled title: String,
        app: XCUIApplication
    ) -> Bool {
        guard let row = findInboxRow(containing: title, in: app) else {
            return false
        }

        for _ in 0..<2 {
            row.press(forDuration: 1.2)
            if app.buttons["View Episode Details"].waitForExistence(timeout: 4) {
                break
            }
        }
        let actionButton = app.buttons[action]
        if actionButton.waitForExistence(timeout: 2), actionButton.isEnabled {
            actionButton.tap()
            return true
        }
        dismissContextMenu(app)
        return false
    }

    /// Finds an episode row in the Inbox by scrolling from the top through the
    /// first screens. The list is virtualized, so only realized rows match —
    /// bounded swipes realize successive screens.
    @MainActor
    private func findInboxRow(containing episodeTitle: String, in app: XCUIApplication) -> XCUIElement? {
        openSection("Inbox", in: app)
        sleep(1)

        let list = app.collectionViews.firstMatch
        let row = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "episode-row-",
                episodeTitle
            )
        ).firstMatch
        // Search downward from the current offset, then recover upward —
        // deliberate scroll-to-top swipes overscroll into pull-to-refresh,
        // which would contaminate the load scenario with feed refreshes.
        for _ in 0..<5 {
            if row.exists, row.isHittable {
                return row
            }
            list.swipeUp()
            usleep(700_000)
        }
        for _ in 0..<7 {
            if row.exists, row.isHittable {
                return row
            }
            list.swipeDown()
            usleep(700_000)
        }
        return row.exists && row.isHittable ? row : nil
    }

    @MainActor
    private func dismissContextMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        usleep(600_000)
    }

    @MainActor
    private func dismissNowPlayingIfPresented(_ app: XCUIApplication) {
        let overlay = app.otherElements["Now Playing"]
        guard overlay.exists, overlay.isHittable else {
            return
        }

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
    }

    @MainActor
    private func tapProbeMark(_ app: XCUIApplication) {
        let button = app.buttons["Probe Mark"]
        guard button.exists, button.isHittable else {
            print("SCROLLPROBE: probe mark button unavailable at mark time")
            return
        }
        button.tap()
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(_ value: String, named name: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
