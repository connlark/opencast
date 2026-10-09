import XCTest

/// Matched, opt-in workloads for Instruments and XCTest hitch metrics. The
/// in-memory library leaves the device's subscriptions and downloads intact.
final class InteractionPerformanceUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPENCAST_INTERACTION_PERF"] == "1",
            "Set TEST_RUNNER_OPENCAST_INTERACTION_PERF=1 to run interaction profiling."
        )
        continueAfterFailure = false
    }

    @MainActor
    func testInboxScrollingDuringPlayback() {
        measureScrolling(section: "Inbox", layout: "list")
    }

    @MainActor
    func testRealInboxScrollingDuringPlayback() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPENCAST_INTERACTION_REAL_LIBRARY"] == "1",
            "The real-library workload requires a second explicit opt-in."
        )
        measureScrolling(section: "Inbox", layout: "list", usesRealLibrary: true)
    }

    @MainActor
    func testLibraryListScrollingDuringPlayback() {
        measureScrolling(section: "Library", layout: "list")
    }

    @MainActor
    func testLibraryGridScrollingDuringPlayback() {
        measureScrolling(section: "Library", layout: "grid")
    }

    @MainActor
    func testMiniPlayerExpansionDuringPlayback() {
        let app = makeApp(layout: "list")
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            launchPlaying(app)
            app.tabBars.buttons["Inbox"].tap()
            waitForTraceIfRequested()
            startMeasuring()
            app.buttons["Open Now Playing"].tap()
            XCTAssertTrue(app.sliders["Playback Progress"].waitForExistence(timeout: 10))
            stopMeasuring()
            if frameProbeEnabled {
                let summary = captureFramePacingSummary(in: app, expectedSessions: 1, containing: "card-settled")
                XCTAssertTrue(summary.contains("card-settled"))
            }
            app.terminate()
        }
    }

    @MainActor
    private func measureScrolling(section: String, layout: String, usesRealLibrary: Bool = false) {
        let app = makeApp(layout: layout, usesRealLibrary: usesRealLibrary)
        if frameProbeEnabled { app.launchArguments.append("--opencast-frame-probe-window") }
        launchPlaying(app)
        app.tabBars.buttons[section].tap()
        let list = layout == "grid" && section == "Library"
            ? app.scrollViews["Library Grid"]
            : app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        // Resource metrics bind to the running process. Keep it alive across
        // iterations so they never sample the PID of an earlier launch.
        defer { app.terminate() }
        var windowIndex = 0
        measure(
            metrics: [
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                XCTHitchMetric(application: app),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app)
            ],
            options: measureOptions
        ) {
            waitForTraceIfRequested()
            windowIndex += 1
            let sessionsBefore = frameProbeEnabled ? frameSummaryValue(in: app).components(separatedBy: "session=").count - 1 : 0
            if frameProbeEnabled {
                XCTAssertTrue(app.buttons["Probe Mark"].waitForExistence(timeout: 10))
                app.buttons["Probe Mark"].tap()
            }
            startMeasuring()
            for _ in 0..<6 {
                list.swipeUp(velocity: .fast)
            }
            for _ in 0..<3 {
                list.swipeDown(velocity: .fast)
            }
            stopMeasuring()
            if frameProbeEnabled {
                app.buttons["Probe Mark"].tap()
                let summary = captureFramePacingSummary(
                    in: app, expectedSessions: sessionsBefore + 1, containing: "probe-window-end-\(windowIndex)"
                )
                let newSessions = summary.components(separatedBy: " || ").filter { $0.contains("session=") }.dropFirst(sessionsBefore)
                XCTAssertTrue(newSessions.contains { session in
                    session.contains("probe-window-start-\(windowIndex)@") && session.contains("probe-window-end-\(windowIndex)@")
                        && !session.contains("frames=0") && !session.contains("maxGap=unavailable")
                }, "Expected one complete scroll frame window: \(summary)")
            }
            XCTAssertTrue(app.buttons["Open Now Playing"].exists)
        }
    }

    private var measureOptions: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = Int(ProcessInfo.processInfo.environment["OPENCAST_INTERACTION_PERF_ITERATIONS"] ?? "") ?? 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    @MainActor
    private func makeApp(layout: String, usesRealLibrary: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if ProcessInfo.processInfo.environment["OPENCAST_FRAME_PROBE"] == "1" {
            app.launchArguments.append("--opencast-frame-probe")
        }
        if usesRealLibrary {
            return app
        }
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-ui-library",
            "--opencast-seed-episode-progress"
        ]
        app.launchEnvironment["OPENCAST_SEED_EXTRA_FEED_COUNT"] = "320"
        app.launchEnvironment["OPENCAST_SEED_ARTWORK_PREVIEW"] = "1"
        app.launchEnvironment["OPENCAST_SEED_VARIED_ARTWORK_PREVIEWS"] = "1"
        app.launchEnvironment["OPENCAST_UI_TEST_ARTWORK_VARIANT"] = "placeholder"
        app.launchEnvironment["OPENCAST_SEED_LIBRARY_LAYOUT"] = layout
        app.launchEnvironment["OPENCAST_SEED_AUDIO_DURATION_SECONDS"] = "600"
        return app
    }

    @MainActor
    private func launchPlaying(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["Open Now Playing"].waitForExistence(timeout: 30))
        let play = app.buttons["Play"].firstMatch
        if play.exists {
            play.tap()
        }
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10))
    }

    private func waitForTraceIfRequested() {
        if let seconds = Double(ProcessInfo.processInfo.environment["OPENCAST_INTERACTION_TRACE_WAIT"] ?? ""),
           seconds > 0 {
            Thread.sleep(forTimeInterval: min(seconds, 60))
        }
    }

    private var frameProbeEnabled: Bool {
        ProcessInfo.processInfo.environment["OPENCAST_FRAME_PROBE"] == "1"
    }
}
