import XCTest

/// Phase 11 Extended-QA device probes (`notes/plans/bugfixes-galore/STATUS.md`):
/// the model-download watch (workstream A), the checkpoint kill-soak driver
/// (F), the long-episode transcript screens pass (E/D), and the real-library
/// artwork scroll (C/H/I). Launches the real app — no seeding seams, real
/// store — on a physical device.
///
/// Opt-in via `TEST_RUNNER_OPENCAST_EXTENDED_QA=1`; each leg is a separate
/// test method addressed with `-only-testing` so device state can be arranged
/// and harvested host-side (transcript documents, SwiftData records) between
/// invocations. Progress samples print as `EXTQA[...]` lines for host
/// parsing.
final class ExtendedQADeviceProbeUITests: XCTestCase {
    private static let optInEnvironmentKey = "OPENCAST_EXTENDED_QA"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1",
            "extended-QA probes are opt-in; set TEST_RUNNER_OPENCAST_EXTENDED_QA=1"
        )
        continueAfterFailure = false
    }

    // MARK: - Targets (env-overridable, mirroring ScrollJankDeviceProbeUITests)

    private static func environmentValue(_ key: String, default defaultValue: String) -> String {
        let value = ProcessInfo.processInfo.environment["OPENCAST_EXTQA_\(key)"]
        return value?.isEmpty == false ? value! : defaultValue
    }

    /// The screens pass needs a long, already-transcribed episode from the
    /// runner device's own library, so both targets are supplied per run via
    /// `TEST_RUNNER_OPENCAST_EXTQA_LONG_PODCAST` /
    /// `TEST_RUNNER_OPENCAST_EXTQA_LONG_EPISODE`. No library content is
    /// hardcoded here.
    private static var longPodcastTitle: String { environmentValue("LONG_PODCAST", default: "") }
    private static var longEpisodeTitle: String { environmentValue("LONG_EPISODE", default: "") }

    // MARK: - A: model-download watch

    /// Fresh tiny.en install watching the bar move mid-file: deletes the Fast
    /// model if installed, reinstalls it, and samples the settings status row
    /// throughout. Passing requires the completed-byte reading to move at
    /// least twice strictly between 0 and the total — pre-Phase-11 the bar
    /// only moved at per-file boundaries, and post-Phase-11 the delegate's
    /// mid-file callback feeds it continuously.
    @MainActor
    func testFreshFastModelInstallShowsMidFileProgress() throws {
        let app = launchApp()
        openTranscriptionSettings(in: app)

        if scrollToButton("Delete Fast Model", in: app) {
            app.buttons["Delete Fast Model"].tap()
            confirmDialogButton("Delete Fast Model", in: app)
            XCTAssertTrue(
                waitForStatus(prefix: "Not Installed", in: app, timeout: 60),
                "Fast model delete should settle to Not Installed"
            )
            print("EXTQA[fast-install]: deleted pre-existing Fast model")
        }

        XCTAssertTrue(scrollToButton("Install Fast Model", in: app), "Install Fast Model button must exist")
        app.buttons["Install Fast Model"].tap()
        confirmDialogButton("Install Fast Model", in: app)

        let samples = sampleInstallProgress(in: app, timeout: 300, label: "fast-install")
        XCTAssertTrue(
            waitForStatus(prefix: "Installed,", in: app, timeout: 120),
            "Fast model install should settle to Installed"
        )
        assertMidFileMovement(samples, minimumDistinctMidValues: 2, label: "fast-install")
    }

    /// Accurate (large-v3, ~630 MB) fresh install with a mid-download cancel
    /// and a restart to completion. The 402 MB AudioEncoder file dominates the
    /// byte range, so a rich strictly-increasing sample set proves mid-file
    /// progress; the cancel must settle back to Not Installed (delete-on-
    /// failure contract) and the restart must complete. Restores the picker to
    /// Fast afterwards so later transcription legs keep using tiny.
    @MainActor
    func testAccurateModelInstallMidFileProgressCancelRestart() throws {
        let app = launchApp()
        openWhisperModelDiagnostics(in: app)

        app.buttons["Accurate"].tap()
        usleep(500_000)

        XCTAssertTrue(scrollToButton("Install Accurate Model", in: app), "Install Accurate Model button must exist")
        app.buttons["Install Accurate Model"].tap()
        confirmDialogButton("Install Accurate Model", in: app)

        let cancelSamples = sampleInstallProgress(
            in: app,
            timeout: 600,
            label: "accurate-cancel-leg",
            cancelAtFraction: 0.4
        )
        XCTAssertTrue(
            waitForStatus(prefix: "Not Installed", in: app, timeout: 60),
            "cancelled Accurate install should settle to Not Installed"
        )
        print("EXTQA[accurate-cancel-leg]: cancel settled to Not Installed after \(cancelSamples.count) samples")

        XCTAssertTrue(scrollToButton("Install Accurate Model", in: app), "Install button should return after cancel")
        app.buttons["Install Accurate Model"].tap()
        confirmDialogButton("Install Accurate Model", in: app)

        let samples = sampleInstallProgress(in: app, timeout: 900, label: "accurate-install")
        XCTAssertTrue(
            waitForStatus(prefix: "Installed,", in: app, timeout: 300),
            "Accurate model install should settle to Installed"
        )
        assertMidFileMovement(samples, minimumDistinctMidValues: 10, label: "accurate-install")

        app.buttons["Fast"].tap()
        usleep(500_000)
        XCTAssertTrue(
            waitForStatus(prefix: "Installed,", in: app, timeout: 30),
            "Fast model should still be installed after restoring the picker"
        )
    }

    /// End-of-QA cleanup: deletes the Accurate model and restores the Fast
    /// selection, returning the device to its pre-QA model state.
    @MainActor
    func testDeleteAccurateModelRestoreFastSelection() throws {
        let app = launchApp()
        openWhisperModelDiagnostics(in: app)

        app.buttons["Accurate"].tap()
        usleep(500_000)
        if scrollToButton("Delete Accurate Model", in: app) {
            app.buttons["Delete Accurate Model"].tap()
            confirmDialogButton("Delete Accurate Model", in: app)
            XCTAssertTrue(
                waitForStatus(prefix: "Not Installed", in: app, timeout: 60),
                "Accurate model delete should settle to Not Installed"
            )
        }
        app.buttons["Fast"].tap()
        usleep(500_000)
        XCTAssertTrue(
            waitForStatus(prefix: "Installed,", in: app, timeout: 30),
            "Fast model should remain installed after cleanup"
        )
    }

    // MARK: - Engine selection (kill-soak precondition)

    /// Turns "Use Apple Transcription" off and verifies the switch actually
    /// settled off, so the checkpoint kill-soak runs on Whisper (Apple Speech
    /// restarts from zero and persists no checkpoint). The soak itself is
    /// driven by device launches of the DEBUG panel-transcribe probe rather
    /// than menu automation.
    @MainActor
    func testDisableAppleTranscriptionPreference() throws {
        let app = launchApp()
        openSection("Settings", in: app)
        sleep(1)

        let toggle = app.switches["Use Apple Transcription"].firstMatch
        guard toggle.waitForExistence(timeout: 10) else {
            print("EXTQA[engine]: toggle absent — Apple Speech unavailable, already on Whisper")
            return
        }

        // `isHittable` is true even when the row sits below the visible
        // window, so scroll until the switch is genuinely on screen before
        // tapping — otherwise the tap lands nowhere and the preference
        // silently stays put.
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
        for _ in 0..<8 where !isFullyOnScreen(toggle, in: app) {
            list.swipeUp()
            usleep(600_000)
        }
        print("EXTQA[engine]: frame=\(toggle.frame) window=\(app.frame) onScreen=\(isFullyOnScreen(toggle, in: app))")

        // The switch element spans the whole Form row; its center is the
        // label, so the control itself only responds near the trailing edge.
        let attempts: [(String, () -> Void)] = [
            ("trailing-edge", { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }),
            ("row-center", { toggle.tap() }),
            ("trailing-edge-retry", { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap() })
        ]
        for (name, action) in attempts where (toggle.value as? String) != "0" {
            action()
            usleep(1_200_000)
            let errorText = app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Unable to update transcription"))
                .firstMatch
            print("EXTQA[engine]: \(name) -> value=\((toggle.value as? String) ?? "nil") appError=\(errorText.exists ? errorText.label : "none")")
        }

        XCTAssertEqual(
            toggle.value as? String,
            "0",
            "Use Apple Transcription must settle off for the Whisper kill-soak"
        )
    }

    /// The screens pass: with the frame probe armed, opens the 3 h episode's
    /// detail and transcript, scrolls the transcript, toggles Now Playing over
    /// it, and opens the share menu — bracketed by probe marks. Frame-gap
    /// histograms print as `EXTQA-FRAMES` lines for the ledger.
    @MainActor
    func testLongEpisodeTranscriptScreensFramePacing() throws {
        try XCTSkipIf(
            Self.longPodcastTitle.isEmpty || Self.longEpisodeTitle.isEmpty,
            "set TEST_RUNNER_OPENCAST_EXTQA_LONG_PODCAST and …_LONG_EPISODE to a transcribed episode on the runner device"
        )

        let app = launchApp(frameProbe: true)
        openEpisodeDetail(podcast: Self.longPodcastTitle, episode: Self.longEpisodeTitle, in: app)

        XCTAssertTrue(
            app.buttons["Probe Mark"].waitForExistence(timeout: 10),
            "frame probe must be armed for the screens pass"
        )

        tapProbeMark(app)
        let transcriptCard = app.buttons["Read Transcript"]
        XCTAssertTrue(transcriptCard.waitForExistence(timeout: 10), "Read Transcript card must exist")
        transcriptCard.tap()
        sleep(2)
        tapProbeMark(app)

        let scrollTarget = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
        for _ in 0..<3 {
            scrollTarget.swipeUp(velocity: .fast)
            scrollTarget.swipeDown(velocity: .fast)
        }
        tapProbeMark(app)

        startPlaybackFromTranscript(in: app)
        tapProbeMark(app)

        openShareMenu(in: app)
        tapProbeMark(app)

        sleep(3)
        let summary = frameSummaryValue(in: app)
        attach(summary, named: "ExtendedQA-TranscriptScreens")
        print("EXTQA-FRAMES[transcript-screens]: \(summary)")
        XCTAssertTrue(summary.contains("session="), "expected probe sessions, got: \(summary)")
    }

    // MARK: - C/H/I: real-library artwork scroll

    /// Real-store artwork scroll with a memory gauge: probe-marked fast flick
    /// scrolls through the Inbox and the Library grid inside an
    /// `XCTMemoryMetric` measurement, with the frame-gap histogram printed for
    /// comparison against the 2026-07-22 baselines.
    @MainActor
    func testRealLibraryArtworkScrollMemoryAndFramePacing() throws {
        let app = launchApp(frameProbe: true)
        openSection("Inbox", in: app)
        sleep(2)
        XCTAssertTrue(
            app.buttons["Probe Mark"].waitForExistence(timeout: 10),
            "frame probe must be armed for the scroll pass"
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
            tapProbeMark(app)
            for _ in 0..<4 {
                list.swipeUp(velocity: .fast)
                tapProbeMark(app)
                list.swipeDown(velocity: .fast)
                tapProbeMark(app)
            }
            openSection("Library", in: app)
            sleep(1)
            let library = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
            tapProbeMark(app)
            for _ in 0..<2 {
                library.swipeUp(velocity: .fast)
                tapProbeMark(app)
                library.swipeDown(velocity: .fast)
                tapProbeMark(app)
            }
            openSection("Inbox", in: app)
        }

        sleep(3)
        let summary = frameSummaryValue(in: app)
        attach(summary, named: "ExtendedQA-ArtworkScroll")
        print("EXTQA-FRAMES[artwork-scroll]: \(summary)")
        XCTAssertTrue(summary.contains("session="), "expected probe sessions, got: \(summary)")
    }

    /// XCUITest reports off-window rows as hittable, so verify the element's
    /// frame actually lies inside the app window before trusting a tap.
    @MainActor
    private func isFullyOnScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else {
            return false
        }
        let window = app.frame
        let frame = element.frame
        return frame.minY >= window.minY && frame.maxY <= window.maxY
            && frame.minX >= window.minX && frame.maxX <= window.maxX
    }

    // MARK: - Launch and navigation helpers

    @MainActor
    private func launchApp(frameProbe: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if frameProbe {
            app.launchArguments.append("--opencast-frame-probe")
        }
        app.launch()
        return app
    }

    @MainActor
    private func openTranscriptionSettings(in app: XCUIApplication) {
        openSection("Settings", in: app)
        sleep(1)
        XCTAssertTrue(
            scrollToButton("Install Fast Model", in: app) || scrollToButton("Delete Fast Model", in: app)
                || scrollToButton("Cancel Install", in: app),
            "Transcription section must be reachable in Settings"
        )
    }

    @MainActor
    private func openWhisperModelDiagnostics(in app: XCUIApplication) {
        openSection("Settings", in: app)
        sleep(1)
        XCTAssertTrue(scrollToButton("Diagnostics", in: app), "Diagnostics row must exist in Settings")
        app.buttons["Diagnostics"].tap()
        sleep(1)
        XCTAssertTrue(
            app.buttons["Accurate"].waitForExistence(timeout: 10),
            "Whisper Model picker must exist in Diagnostics"
        )
    }

    /// Scrolls the frontmost list until a button with the given label exists
    /// and is hittable. Returns false when it never appears.
    @MainActor
    private func scrollToButton(_ label: String, in app: XCUIApplication) -> Bool {
        let button = app.buttons[label]
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
        for _ in 0..<8 {
            if button.exists, button.isHittable {
                return true
            }
            list.swipeUp()
            usleep(500_000)
        }
        for _ in 0..<10 {
            if button.exists, button.isHittable {
                return true
            }
            list.swipeDown()
            usleep(500_000)
        }
        return button.exists && button.isHittable
    }

    @MainActor
    private func confirmDialogButton(_ label: String, in app: XCUIApplication) {
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        // The confirmation dialog repeats the trigger's label; the dialog copy
        // is the last hittable match.
        if let dialogButton = confirm.last(where: { $0.exists && $0.isHittable }), confirm.count > 1 {
            dialogButton.tap()
        } else if let only = confirm.first(where: { $0.exists && $0.isHittable }) {
            only.tap()
        }
    }

    // MARK: - Install-status sampling

    private struct InstallSample {
        let at: Date
        let text: String
    }

    /// Samples the settings status row while an install runs, printing every
    /// distinct reading. Optionally cancels the install once the completed
    /// fraction crosses `cancelAtFraction`.
    @MainActor
    private func sampleInstallProgress(
        in app: XCUIApplication,
        timeout: TimeInterval,
        label: String,
        cancelAtFraction: Double? = nil
    ) -> [InstallSample] {
        var samples: [InstallSample] = []
        var lastText = ""
        let deadline = Date.now.addingTimeInterval(timeout)
        let installingTexts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Installing,"))

        while Date.now < deadline {
            let element = installingTexts.firstMatch
            guard element.exists else {
                if samples.isEmpty {
                    usleep(150_000)
                    continue
                }
                break
            }
            let text = element.label
            if text != lastText {
                lastText = text
                samples.append(InstallSample(at: .now, text: text))
                print("EXTQA[\(label)]: \(text)")
                if let cancelAtFraction,
                   let fraction = installedFraction(from: text),
                   fraction >= cancelAtFraction {
                    print("EXTQA[\(label)]: cancelling at fraction \(fraction)")
                    if scrollToButton("Cancel Install", in: app) {
                        app.buttons["Cancel Install"].tap()
                    }
                    break
                }
            }
            usleep(150_000)
        }
        return samples
    }

    /// Parses "Installing, 12.3 MB of 49 MB" into a completed fraction.
    private func installedFraction(from text: String) -> Double? {
        let pattern = #/([0-9][0-9.,]*)\s*(KB|MB|GB)/#
        let matches = text.matches(of: pattern)
        guard matches.count >= 2 else {
            return nil
        }
        func bytes(_ match: Regex<(Substring, Substring, Substring)>.Match) -> Double? {
            guard let value = Double(match.1.replacing(",", with: "")) else {
                return nil
            }
            let scale: Double = switch match.2 {
            case "KB": 1_000
            case "MB": 1_000_000
            default: 1_000_000_000
            }
            return value * scale
        }
        guard let completed = bytes(matches[0]), let total = bytes(matches[1]), total > 0 else {
            return nil
        }
        return completed / total
    }

    private func assertMidFileMovement(
        _ samples: [InstallSample],
        minimumDistinctMidValues: Int,
        label: String
    ) {
        let fractions = samples.compactMap { installedFraction(from: $0.text) }
        let midValues = fractions.filter { $0 > 0 && $0 < 1 }
        print("EXTQA[\(label)]: \(samples.count) samples, \(midValues.count) strictly mid-install readings")
        XCTAssertGreaterThanOrEqual(
            midValues.count,
            minimumDistinctMidValues,
            "\(label): expected the progress bar to move mid-install (got \(midValues.count) mid readings from \(samples.count) samples)"
        )
        XCTAssertEqual(
            midValues,
            midValues.sorted(),
            "\(label): completed-byte readings must be monotonically nondecreasing"
        )
    }

    @MainActor
    private func waitForStatus(prefix: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let match = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    // MARK: - Episode navigation and actions

    @MainActor
    private func ensureWhisperEngineSelected(in app: XCUIApplication) {
        openSection("Settings", in: app)
        sleep(1)
        let toggle = app.switches["Use Apple Transcription"]
        guard toggle.waitForExistence(timeout: 3) else {
            return
        }
        let isOn = (toggle.value as? String) == "1"
        if isOn {
            toggle.tap()
            usleep(800_000)
            print("EXTQA[setup]: disabled Use Apple Transcription for the Whisper legs")
        }
    }

    @MainActor
    private func openEpisodeDetail(podcast: String, episode: String, in app: XCUIApplication) {
        openSection("Library", in: app)
        sleep(1)

        let podcastElement = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", podcast)
        ).firstMatch
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
        for _ in 0..<8 where !(podcastElement.exists && podcastElement.isHittable) {
            list.swipeUp()
            usleep(500_000)
        }
        XCTAssertTrue(podcastElement.exists && podcastElement.isHittable, "podcast \(podcast) must be in the Library")
        podcastElement.tap()
        sleep(1)

        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "episode-row-", episode)
        ).firstMatch
        let episodeList = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
        for _ in 0..<10 where !(row.exists && row.isHittable) {
            episodeList.swipeUp()
            usleep(500_000)
        }
        XCTAssertTrue(row.exists && row.isHittable, "episode \(episode) must be listed for \(podcast)")

        for _ in 0..<2 {
            row.press(forDuration: 1.2)
            if app.buttons["View Episode Details"].waitForExistence(timeout: 4) {
                break
            }
        }
        let detailButton = app.buttons["View Episode Details"]
        XCTAssertTrue(detailButton.exists, "context menu must offer View Episode Details")
        detailButton.tap()
        XCTAssertTrue(
            app.buttons["Episode Actions"].waitForExistence(timeout: 10),
            "episode detail must present the Episode Actions menu"
        )
    }

    // MARK: - Screens-pass helpers

    @MainActor
    private func startPlaybackFromTranscript(in app: XCUIApplication) {
        let miniPlayer = app.otherElements["Now Playing"]
        if miniPlayer.exists, miniPlayer.isHittable {
            miniPlayer.tap()
            sleep(2)
            dismissNowPlaying(in: app)
            return
        }
        // No active playback: nothing to toggle over the transcript. The
        // screens pass still records transcript scroll + share pacing.
        print("EXTQA-FRAMES[transcript-screens]: no Now Playing surface to toggle")
    }

    @MainActor
    private func dismissNowPlaying(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
    }

    @MainActor
    private func openShareMenu(in app: XCUIApplication) {
        let menu = app.buttons["Transcript Options"]
        guard menu.waitForExistence(timeout: 5) else {
            print("EXTQA-FRAMES[transcript-screens]: Transcript Options menu not found")
            return
        }
        menu.tap()
        let share = app.buttons["Share Transcript"]
        if share.waitForExistence(timeout: 3) {
            share.tap()
            sleep(2)
            // Dismiss the share sheet.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            sleep(1)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            usleep(600_000)
        }
    }

    // MARK: - Frame probe helpers

    @MainActor
    private func tapProbeMark(_ app: XCUIApplication) {
        let button = app.buttons["Probe Mark"]
        guard button.exists, button.isHittable else {
            print("EXTQA-FRAMES: probe mark button unavailable at mark time")
            return
        }
        button.tap()
    }

    @MainActor
    private func frameSummaryValue(in app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["Frame Pacing Summary"]
        guard element.waitForExistence(timeout: 10) else {
            return "frame probe element missing"
        }
        return (element.value as? String) ?? ""
    }

    @MainActor
    private func attach(_ value: String, named name: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
