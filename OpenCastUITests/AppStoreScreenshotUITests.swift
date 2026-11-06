import ImageIO
import UIKit
import XCTest

/// The set a run captures. The iPhone and iPad sets follow the destination;
/// the iPhone Duo's two sets, one per display, exist only when the runner
/// names them (`TEST_RUNNER_OPENCAST_SCREENSHOT_FAMILY=duoOuter|duoInner`)
/// and the screen's pixels agree.
enum AppStoreScreenshotFamily: String {
    case iphone
    case ipad
    case duoOuter
    case duoInner

    /// The pixel size of a Duo set's screen (one of `XCUIScreen.screens`):
    /// the outer display portrait (Closed at rotation 0), the inner display
    /// in its landscape-native orientation (fully Open at rotation 0). Nil for
    /// the iPhone and iPad, which keep their destination check.
    var requiredScreenPixels: (width: Int, height: Int)? {
        switch self {
        case .duoOuter:
            (1398, 2034)
        case .duoInner:
            (2853, 2007)
        case .iphone, .ipad:
            nil
        }
    }

    var isDuo: Bool {
        requiredScreenPixels != nil
    }

    /// The inner display's frames are taken on the host (`simctl io …
    /// --display=LCD-1`) on the test's cue: XCTest's screen for it is
    /// portrait and one pixel short of the display (2006×2852).
    var capturesOnHost: Bool {
        self == .duoInner
    }
}

final class AppStoreScreenshotUITests: XCTestCase {
    private static let primaryFeedURL = "https://screenshots.opencast.example/orbit-report.xml"
    private static let primaryEpisodeID = "app-store-orbit-report-episode-1"
    private static let pipelineEpisodeID = "app-store-orbit-report-episode-3"
    private static let searchQuery = "light"
    private static let searchResultEpisodeIDs = [
        "app-store-greenhouse-hours-episode-1",
        "app-store-paper-lanterns-episode-1",
        primaryEpisodeID
    ]
    private static let upNextEpisodeIDs = [
        "app-store-kitchen-table-episode-1",
        "app-store-long-way-round-episode-1",
        "app-store-half-time-episode-1"
    ]
    private static let primarySubscriptionRowIdentifier = "subscription-row-\(primaryFeedURL)"
    private static let autoSkipPillArgument = "--opencast-pin-app-store-autoskip-pill"
    private static let forceOnboardingArgument = "--opencast-force-onboarding"
    private static let queueOverrideEnvironmentKey = "OPENCAST_UI_TEST_AD_FREE_PASS_QUEUE_OVERRIDE"
    private static let queueOverrideProgressEnvironmentKey = "OPENCAST_UI_TEST_AD_FREE_PASS_QUEUE_OVERRIDE_PROGRESS"
    private static let familyEnvironmentKey = "OPENCAST_SCREENSHOT_FAMILY"
    private static let cueDirectoryEnvironmentKey = "OPENCAST_SCREENSHOT_CUE_DIR"
    private static let cueBoundEnvironmentKey = "OPENCAST_SCREENSHOT_CUE_BOUND_SECONDS"

    /// The inner skip hero uses the last line before the end-of-show promo
    /// (4:26-4:32) and the promo's first line. A 4:26 or 4:27 reading
    /// triggers the pause; paused readings must remain in 266..<272 seconds,
    /// and the post-frame reading must remain below 272 seconds.
    private static let innerSkipCurrentLine = "So that's first light:"
    private static let innerSkipPromoLine = "If this episode kept you up past bedtime"
    private static let innerSkipPauseWindow: ClosedRange<TimeInterval> = 266...267
    private static let innerSkipPromoStart: TimeInterval = 272

    /// The App Store name each set captures a slug under; the compositor's
    /// `lib/spec.mjs` owns the order, layout and captions. A slug with no
    /// entry for the set is not captured, and a flow that serves only such
    /// slugs does not run.
    ///
    /// The Duo's two sets are one App Store set of ten (outer 01-05, inner
    /// 06-10); the family token follows the number.
    private static let shotNames: [String: [AppStoreScreenshotFamily: String]] = [
        "skip": [
            .iphone: "app_store_01_skip",
            .ipad: "app_store_01_skip",
            .duoOuter: "app_store_01_duoOuter_skip",
            .duoInner: "app_store_06_duoInner_skip"
        ],
        "transcript": [
            .iphone: "app_store_02_transcript",
            .ipad: "app_store_03_transcript",
            .duoOuter: "app_store_02_duoOuter_transcript"
        ],
        "sound_lab": [
            .iphone: "app_store_03_sound_lab",
            .ipad: "app_store_06_sound_lab",
            .duoOuter: "app_store_03_duoOuter_sound_lab"
        ],
        "search": [
            .iphone: "app_store_04_search",
            .ipad: "app_store_04_search",
            .duoOuter: "app_store_04_duoOuter_search",
            .duoInner: "app_store_09_duoInner_search"
        ],
        "chapters": [
            .iphone: "app_store_05_chapters",
            .ipad: "app_store_05_chapters",
            .duoInner: "app_store_08_duoInner_chapters"
        ],
        "pipeline": [.iphone: "app_store_06_pipeline"],
        "notification": [.iphone: "app_store_07_notification"],
        "library": [.iphone: "app_store_08_library", .duoOuter: "app_store_05_duoOuter_library"],
        "welcome": [.iphone: "app_store_09_welcome"],
        "up_next": [.iphone: "app_store_10_up_next", .duoInner: "app_store_10_duoInner_up_next"],
        "library_grid": [.ipad: "app_store_02_library_grid", .duoInner: "app_store_07_duoInner_library_grid"]
    ]

    /// Resolved at the start of `testAppStoreScreenshotSet`; every other test
    /// keeps the iPhone default and so today's gestures.
    private var family = AppStoreScreenshotFamily.iphone

    /// A Duo set's own screen, found by its pixels among `XCUIScreen.screens`:
    /// the device's main screen stays the outer display when it is open, so
    /// `XCUIScreen.main` is never the inner display. Nil for the iPhone and
    /// iPad, which keep the main screen.
    @MainActor
    private var familyScreen: XCUIScreen?

    /// The host directory a host-captured set cues its frames through, the
    /// wait for each answer (derived by the capture script from the frame
    /// latency it measured), and the cues' running number.
    private var hostCueDirectory: URL?
    private var hostCueBound: TimeInterval = 0
    private var hostCueSequence = 0

    // The runner's own idiom has evaluated non-pad on iPad destinations, so
    // this shares the pad tests' model-string-based decision.
    @MainActor
    private var isPad: Bool {
        OpenCastPadUITests.isPadDestination(
            environment: ProcessInfo.processInfo.environment,
            deviceModel: UIDevice.current.model,
            isPadIdiom: UIDevice.current.userInterfaceIdiom == .pad
        )
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Capture order differs from App Store order. One base launch carries the
    // library, transcript, chapters, pipeline, search, Sound Lab, and Up Next
    // frames; the ad-skip hero, the welcome page, and the notification each
    // relaunch with their own flag so a pinned pill or forced onboarding
    // never leaks into another frame. The notification goes last so its
    // banner cannot contaminate anything. Playback is paused right after the
    // scrub into the sponsor read so the transcript's follow-along line stays
    // inside the flagged segment however long the earlier captures take.
    @MainActor
    func testAppStoreScreenshotSet() throws {
        family = try requestedFamily()
        resolveFamilyScreen()
        verifyFamilyPixels("when the run starts")
        let app = makeAppStoreScreenshotApp()
        app.launchEnvironment[Self.queueOverrideEnvironmentKey] = "transcribing:\(Self.pipelineEpisodeID)"
        app.launchEnvironment[Self.queueOverrideProgressEnvironmentKey] = "1822/2940"

        if ["transcript", "chapters", "library", "pipeline", "search", "sound_lab"].contains(where: { wants($0) }) {
            launch(app)
            startPrimaryEpisodePlayback(in: app)
            seekIntoSponsorRead(in: app)
            pausePlayback(in: app)
            openCurrentEpisodeDetailFromNowPlaying(in: app)

            if wants("transcript") {
                openTranscriptFromEpisodeDetail(in: app)
                assertExists(sponsorTranscriptRow(in: app), named: "Bottomless Mug sponsor transcript row", timeout: 10)
                capture("transcript")

                tapBackButton(in: app, firstBarOnly: true)
                assertExists(app.buttons["Play Episode"], named: "episode detail after transcript", timeout: 10)
            }

            if wants("chapters") {
                let chaptersCard = element(withIdentifier: "Episode Chapters Card", in: app)
                scrollToRevealNearTop(chaptersCard, in: app)
                assertExists(app.staticTexts["The streak in the corner"], named: "seeded generated chapter")
                capture("chapters")
            }

            if wants("library") {
                openLibrary(in: app)
                assertExists(app.staticTexts["Greenhouse Hours"], named: "Greenhouse Hours library row")
                assertExists(app.staticTexts["Orbit Report"], named: "Orbit Report library row")
                assertExists(miniPlayer(in: app), named: "docked mini player on Library")
                capture("library")
            }

            if wants("pipeline") {
                openPrimaryPodcastDetail(in: app)
                openEpisodeDetailFromContextMenu(episodeID: Self.pipelineEpisodeID, in: app)
                let pipelineCard = element(withIdentifier: "Episode Pipeline Card", in: app)
                scrollUntilHittable(pipelineCard, in: app)
                assertExists(app.staticTexts["Making this episode ad-free"], named: "pipeline card title")
                assertExists(app.staticTexts["30:22 of 49:00"], named: "pipeline transcribe progress")
                capture("pipeline")
            }

            if wants("search") {
                performLibrarySearch(in: app)
                capture("search")
            }

            // The mini player stays reachable under the search results, so the
            // Sound Lab closes the base launch and nothing after the search needs
            // the tab bar (the iPhone bar morphs into the search field; the iPad
            // bar hides outright).
            if wants("sound_lab") {
                openNowPlayingFromMiniPlayer(in: app)
                revealNowPlayingSoundLab(in: app)
                assertExists(nowPlayingSoundLab(in: app), named: "Now Playing Sound Lab panel")
                assertSeededSkipZonesMarked(in: app)
                assertCompletedTranscriptReady(in: app)
                capture("sound_lab")
            }
        }

        if wants("library_grid") {
            // A fresh launch keeps this frame free of the playback accessory.
            // In the iPad portrait flow, leave the navigation sidebar closed so
            // its overlay does not dim the grid or cover its first column.
            launch(app)
            openLibrary(in: app)
            if family == .duoInner {
                // Fully open the Library is a sidebar list beside its selected
                // page, not a grid; a selected show fills the page.
                assertExists(element(withIdentifier: "Library List", in: app), named: "Library sidebar list")
                openPrimaryPodcastDetail(in: app)
            } else {
                assertExists(app.staticTexts["Weeknight Notes"], named: "last library tile")
            }
            capture("library_grid")
        }

        if wants("up_next") {
            // Up Next gets its own launch: the row context menus that fill the
            // queue drop the simulator's status-bar override for the rest of
            // the launch (the Up Next frame bleeds its status bar, the Sound
            // Lab frame does not), and tapping the primary row afterwards
            // opens Now Playing without any dismissal dance.
            launch(app)
            enqueueUpNextEpisodes(in: app)
            startPrimaryEpisodePlayback(in: app)
            if family == .duoInner {
                openUpNextPane(in: app)
            } else {
                openUpNextQueue(in: app)
            }
            capture("up_next")
        }

        app.launchEnvironment.removeValue(forKey: Self.queueOverrideEnvironmentKey)
        app.launchEnvironment.removeValue(forKey: Self.queueOverrideProgressEnvironmentKey)

        if wants("skip") {
            app.launchArguments.append(Self.autoSkipPillArgument)
            launch(app)
            startPrimaryEpisodePlayback(in: app)
            skipPlayback(into: 233...268, named: "just past the mid-roll zone", in: app)
            assertExists(app.descendants(matching: .any)["Skipped promo"], named: "pinned Skipped promo pill")
            if family == .duoInner {
                captureInnerSkipHero(in: app)
            } else {
                capture("skip")
            }
            app.launchArguments.removeAll { $0 == Self.autoSkipPillArgument }
        }

        if wants("welcome") {
            app.launchArguments.append(Self.forceOnboardingArgument)
            launch(app)
            assertExists(
                app.staticTexts["Your listening is not a growth funnel."],
                named: "onboarding welcome pitch",
                timeout: 10
            )
            capture("welcome")
            app.launchArguments.removeAll { $0 == Self.forceOnboardingArgument }
        }

        if wants("notification") {
            try captureEpisodeNotificationScreenshot(app: app)
        }
    }

    // Opt-in variants for the composition bakeoffs (run directly with
    // TEST_RUNNER_OPENCAST_SCREENSHOT_BAKEOFFS=1; the release lane never
    // selects this test). Captures land as raws named bakeoff_* which the
    // compositor spec ignores.
    @MainActor
    func testAppStoreScreenshotBakeoffs() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPENCAST_SCREENSHOT_BAKEOFFS"] == "1",
            "Set OPENCAST_SCREENSHOT_BAKEOFFS=1 to capture the bakeoff variants"
        )

        // Dark appearance: the three frames the plan names for the bakeoff.
        // The pinned pill overlaps the Now Playing title, so the hero gets
        // its own pinned launch after the unpinned chapters and library shots.
        let app = makeAppStoreScreenshotApp(appearanceArgument: "--opencast-force-dark-mode")
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        app.launch()
        startPrimaryEpisodePlayback(in: app)
        pausePlayback(in: app)
        openCurrentEpisodeDetailFromNowPlaying(in: app)
        let chaptersCard = element(withIdentifier: "Episode Chapters Card", in: app)
        scrollToRevealNearTop(chaptersCard, in: app)
        attachAppStoreScreenshot(named: "bakeoff_dark_05_chapters")
        openLibrary(in: app)
        assertExists(miniPlayer(in: app), named: "docked mini player (dark)")
        attachAppStoreScreenshot(named: "bakeoff_dark_08_library")

        app.launchArguments.append(Self.autoSkipPillArgument)
        app.launch()
        startPrimaryEpisodePlayback(in: app)
        skipPlayback(into: 233...268, named: "just past the mid-roll zone (dark)", in: app)
        assertExists(app.descendants(matching: .any)["Skipped promo"], named: "pinned Skipped promo pill (dark)")
        attachAppStoreScreenshot(named: "bakeoff_dark_01_skip")

        // Sound Lab pinned mid-slide.
        app.launchArguments.removeAll { $0 == Self.autoSkipPillArgument || $0 == "--opencast-force-dark-mode" }
        app.launchEnvironment.removeValue(forKey: "OPENCAST_FORCE_DARK_MODE")
        app.launchArguments.append("--opencast-force-light-mode")
        app.launchEnvironment["OPENCAST_PIN_APP_STORE_SOUND_LAB_REVEAL"] = "0.7"
        app.launch()
        startPrimaryEpisodePlayback(in: app)
        seekIntoSponsorRead(in: app)
        pausePlayback(in: app)
        assertExists(nowPlayingSoundLab(in: app), named: "pinned mid-slide Sound Lab panel")
        attachAppStoreScreenshot(named: "bakeoff_sound_lab_mid")

        // Ad Detection queue screen with one running and two pending items.
        app.launchEnvironment.removeValue(forKey: "OPENCAST_PIN_APP_STORE_SOUND_LAB_REVEAL")
        app.launchEnvironment[Self.queueOverrideEnvironmentKey] =
            "transcribing:\(Self.pipelineEpisodeID)|app-store-kitchen-table-episode-2|app-store-half-time-episode-2"
        app.launchEnvironment[Self.queueOverrideProgressEnvironmentKey] = "1822/2940"
        app.launch()
        openInbox(in: app)
        let indicator = app.buttons["Ad Detection Queue"].firstMatch
        assertHittable(indicator, named: "Inbox ad detection indicator")
        indicator.tap()
        assertScreen("Ad Detection", named: "Ad Detection queue screen", in: app)
        assertExists(app.staticTexts["The Quiet Season on the Sun"], named: "running queue row")
        attachAppStoreScreenshot(named: "bakeoff_queue_screen")
    }

    @MainActor
    private func makeAppStoreScreenshotApp(
        appearanceArgument: String = "--opencast-force-light-mode"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: false)
        // setupSnapshot appends the lane's cached launch arguments (including
        // its appearance flag); both appearance flags together resolve to the
        // system appearance, so only the requested one may remain.
        app.launchArguments.removeAll { $0 == "--opencast-force-light-mode" || $0 == "--opencast-force-dark-mode" }
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-seed-app-store-screenshots",
            appearanceArgument,
            "-OPENCAST_REMOTE_TRANSCRIPTION_PURCHASE_FIXTURE",
            "review-screenshot"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_APP_STORE_SCREENSHOTS"] = "1"
        if appearanceArgument == "--opencast-force-light-mode" {
            app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        }
        return app
    }

    // MARK: - Notification

    // The notification is the shot's subject, so this capture path must not
    // use the banner-dismiss helper the app shots rely on. The app stays in
    // the foreground (the delegate presents banners there), so the card lands
    // over the Library instead of a Lock Screen with the simulator's fake
    // date. A long press afterwards captures the expanded rich card as a
    // bakeoff variant; if SpringBoard ignores it the banner shot stands.
    @MainActor
    private func captureEpisodeNotificationScreenshot(app: XCUIApplication) throws {
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Notification Permission") { alert in
            for buttonTitle in ["Allow", "Allow Notifications"] {
                let button = alert.buttons[buttonTitle]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments.append("--opencast-schedule-app-store-episode-notification")
        app.launchEnvironment["OPENCAST_SCHEDULE_APP_STORE_EPISODE_NOTIFICATION"] = "1"
        launch(app)

        // The permission alert is SpringBoard's; a tap into the app to trigger
        // the interruption monitor would land on an Inbox row instead.
        let allowButton = springboard.buttons["Allow"]
        if allowButton.waitForExistence(timeout: 3) {
            allowButton.tap()
        }
        openLibrary(in: app)
        assertExists(app.staticTexts["Greenhouse Hours"], named: "Library behind the notification")

        let banner = springboard.descendants(matching: .any)
            .matching(identifier: "NotificationShortLookView")
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "New-episode banner should appear over the app")
        assertExists(
            springboard.staticTexts["What the New Telescope Saw First"],
            named: "banner episode title",
            timeout: 3
        )
        // The banner is the fallback frame; the expanded rich card (artwork,
        // ORBIT REPORT, 49 MIN) replaces it under the same name when the long
        // press lands, so a failed expansion still leaves a valid shot.
        guard let name = Self.shotNames["notification"]?[family] else {
            return
        }
        verifyFamilyPixels("before \(name)")
        snapshotForFastlane(name)
        attachSmokeScreenshot(named: "bakeoff_notification_banner")

        banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        // "49 MIN" is rendered only by the content extension's expanded card.
        if springboard.staticTexts["49 MIN"].waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 1)
            snapshotForFastlane(name)
        }
        verifyFamilyPixels("before \(name)")
        attachSmokeScreenshot(named: name)
    }

    // MARK: - Captures

    /// Whether the run's set carries `slug`.
    @MainActor
    private func wants(_ slug: String) -> Bool {
        Self.shotNames[slug]?[family] != nil
    }

    /// Captures `slug` under the set's App Store name; nothing for a slug the
    /// set does not carry. `beforeFrame` runs after the pre-frame checks, as
    /// the last step before the frame itself.
    @MainActor
    private func capture(_ slug: String, beforeFrame: () -> Void = {}) {
        guard let name = Self.shotNames[slug]?[family] else {
            return
        }
        attachAppStoreScreenshot(named: name, beforeFrame: beforeFrame)
    }

    @MainActor
    private func attachAppStoreScreenshot(named name: String, beforeFrame: () -> Void = {}) {
        dismissSystemNotificationBanners()
        verifyFamilyPixels("before \(name)")
        beforeFrame()
        snapshotForFastlane(name)
        attachFamilyScreenshot(named: name)
    }

    /// The capture as an attachment: a Duo set's own screen, otherwise the
    /// shared main-screen helper.
    @MainActor
    private func attachFamilyScreenshot(named name: String) {
        if family.capturesOnHost {
            let reading = hostCapture(kind: "shot", name: name)
            assertHostFrame(reading, "for \(name)")
            return
        }
        guard let familyScreen else {
            attachSmokeScreenshot(named: name)
            return
        }
        let attachment = XCTAttachment(screenshot: familyScreen.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Fastlane's `snapshot` file for the iPhone and iPad sets. A Duo set
    /// never runs under snapshot: its frames are the attachments the
    /// capture script exports from the result bundle.
    @MainActor
    private func snapshotForFastlane(_ name: String) {
        guard !family.isDuo else {
            return
        }
        snapshot(name, timeWaitingForIdle: 0)
    }

    // MARK: - Capture family

    /// The set the runner asked for, or the iPhone / iPad destination check
    /// when it asked for none. A requested value must be a Duo set; anything
    /// else fails the run rather than falling back to the iPhone set.
    @MainActor
    private func requestedFamily() throws -> AppStoreScreenshotFamily {
        let requested = ProcessInfo.processInfo.environment[Self.familyEnvironmentKey] ?? ""
        guard !requested.isEmpty else {
            return isPad ? .ipad : .iphone
        }
        guard let family = AppStoreScreenshotFamily(rawValue: requested), family.isDuo else {
            throw ScreenshotFamilyError(
                description: "\(Self.familyEnvironmentKey)=\(requested) is not a Duo set (duoOuter or duoInner)"
            )
        }
        return family
    }

    @MainActor
    private func launch(_ app: XCUIApplication) {
        app.launch()
        verifyFamilyPixels("after a launch")
    }

    /// Finds a Duo set's screen: exactly one of `XCUIScreen.screens` whose
    /// screenshot PNG has the set's pixel size.
    @MainActor
    private func resolveFamilyScreen() {
        guard let required = family.requiredScreenPixels else {
            return
        }
        if family.capturesOnHost {
            let path = ProcessInfo.processInfo.environment[Self.cueDirectoryEnvironmentKey] ?? ""
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "\(family.rawValue) is captured on the host and needs \(Self.cueDirectoryEnvironmentKey), got \(path)"
            )
            hostCueDirectory = URL(fileURLWithPath: path, isDirectory: true)
            let bound = TimeInterval(ProcessInfo.processInfo.environment[Self.cueBoundEnvironmentKey] ?? "") ?? 0
            XCTAssertGreaterThan(bound, 0, "\(family.rawValue) needs \(Self.cueBoundEnvironmentKey), the wait for each host frame")
            hostCueBound = bound
            return
        }
        let screens = XCUIScreen.screens.map { screen in (screen, pixelSize(of: screen)) }
        let matches = screens.filter { $0.1?.width == required.width && $0.1?.height == required.height }
        let sizes = screens.map { $0.1.map { "\($0.width)×\($0.height)" } ?? "unreadable" }.joined(separator: ", ")
        XCTAssertEqual(
            matches.count,
            1,
            "\(family.rawValue) needs exactly one \(required.width)×\(required.height) screen; XCUIScreen.screens are \(sizes)"
        )
        familyScreen = matches.first?.0
    }

    /// A Duo set must match the display the runner is driving, read as the
    /// pixel size of its screen's screenshot PNG: never a point size, the
    /// window or app frame (portrait-shaped in a landscape pose) or the
    /// idiom. Rechecked after every launch and before every capture.
    @MainActor
    private func verifyFamilyPixels(
        _ moment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let required = family.requiredScreenPixels else {
            return
        }
        if family.capturesOnHost {
            assertHostFrame(hostCapture(kind: "probe", name: moment), moment, file: file, line: line)
            return
        }
        let actual = familyScreen.flatMap { pixelSize(of: $0) }
        XCTAssertTrue(
            actual?.width == required.width && actual?.height == required.height,
            "\(family.rawValue) needs a \(required.width)×\(required.height) screen \(moment); "
                + "its screen is \(actual.map { "\($0.width)×\($0.height)" } ?? "missing or unreadable")",
            file: file,
            line: line
        )
    }

    /// Cues the capture script on the host to save the inner display's frame
    /// (a probe or a shot) and waits for its answer: the frame's pixel size,
    /// RGB maximum and sha256, or the host's reason for refusing it. No idle
    /// wait precedes the cue, as none precedes an XCTest screenshot (the
    /// last one is the preceding interaction's). The wait is the bound the
    /// capture script derived; no answer within it fails the run.
    @MainActor
    private func hostCapture(
        kind: String,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (width: Int, height: Int, maximum: Double)? {
        guard let directory = hostCueDirectory else {
            XCTFail("No host cue directory for \(kind) \(name)", file: file, line: line)
            return nil
        }
        hostCueSequence += 1
        let label = name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        let base = String(format: "%04d", hostCueSequence) + "-\(kind)-" + String(label)
        do {
            try Data().write(to: directory.appendingPathComponent("\(base).request"))
        } catch {
            XCTFail("Could not cue the host for \(base): \(error)", file: file, line: line)
            return nil
        }
        let done = directory.appendingPathComponent("\(base).done")
        let failed = directory.appendingPathComponent("\(base).failed")
        let deadline = Date.now.addingTimeInterval(hostCueBound)
        while Date.now < deadline {
            if let answer = try? String(contentsOf: done, encoding: .utf8) {
                let fields = answer.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                guard fields.count == 4, let width = Int(fields[0]), let height = Int(fields[1]),
                      let maximum = Double(fields[2])
                else {
                    XCTFail("Unreadable host answer for \(base): \(answer)", file: file, line: line)
                    return nil
                }
                print("host frame \(base): \(width)x\(height), RGB maximum \(maximum), sha256 \(fields[3])")
                return (width, height, maximum)
            }
            if let reason = try? String(contentsOf: failed, encoding: .utf8) {
                XCTFail("The host could not take \(base): \(reason)", file: file, line: line)
                return nil
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("No host answer for \(base) within \(hostCueBound) s", file: file, line: line)
        return nil
    }

    /// A host frame must be the set's exact pixel size and not black.
    @MainActor
    private func assertHostFrame(
        _ reading: (width: Int, height: Int, maximum: Double)?,
        _ moment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let required = family.requiredScreenPixels else {
            return
        }
        XCTAssertTrue(
            reading?.width == required.width && reading?.height == required.height && (reading?.maximum ?? 0) > 0,
            "\(family.rawValue) needs a nonblack \(required.width)×\(required.height) display frame \(moment); "
                + "the host read \(reading.map { "\($0.width)×\($0.height), RGB maximum \($0.maximum)" } ?? "nothing")",
            file: file,
            line: line
        )
    }

    @MainActor
    private func pixelSize(of screen: XCUIScreen) -> (width: Int, height: Int)? {
        let png = screen.screenshot().pngRepresentation
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    // MARK: - Gesture surface

    /// What a gesture's coordinates come from. The iPhone and iPad sets keep
    /// the app element. A Duo set anchors them to the window-wide `Toolbar`
    /// element the section rail sits under (Closed and Open landscape): in a
    /// landscape pose the app's frame reads portrait-shaped while its
    /// elements are landscape, so a coordinate taken from it lands
    /// elsewhere.
    @MainActor
    private func gestureSurface(in app: XCUIApplication) -> XCUIElement {
        guard family.isDuo else {
            return app
        }
        let toolbar = app.toolbars.firstMatch
        assertExists(toolbar, named: "window-wide Toolbar a Duo gesture is anchored to")
        return toolbar
    }

    @MainActor
    private func swipeContentUp(in app: XCUIApplication) {
        guard family.isDuo else {
            app.swipeUp()
            return
        }
        dragContent(from: 0.75, to: 0.25, in: app)
    }

    @MainActor
    private func swipeContentDown(in app: XCUIApplication) {
        guard family.isDuo else {
            app.swipeDown()
            return
        }
        dragContent(from: 0.25, to: 0.75, in: app)
    }

    /// A quick vertical flick through the middle of the gesture surface,
    /// between two fractions of its height.
    @MainActor
    private func dragContent(from startY: CGFloat, to endY: CGFloat, in app: XCUIApplication) {
        let surface = gestureSurface(in: app)
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
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

    // MARK: - Playback

    // The primary episode is the newest row; after the Inbox has been
    // scrolled (Up Next enqueueing reaches its fourth-day rows) the lazy list
    // no longer holds it, so scroll back up until it does.
    @MainActor
    private func startPrimaryEpisodePlayback(in app: XCUIApplication) {
        openInbox(in: app)
        let primaryEpisode = episodeRow(Self.primaryEpisodeID, in: app)
        for _ in 0..<6 where !isListed(primaryEpisode, in: app) {
            swipeRootListDown(in: app)
            Thread.sleep(forTimeInterval: 0.8)
        }
        assertExists(primaryEpisode, named: "primary inbox episode")
        scrollRootRowUntilHittable(primaryEpisode, in: app)
        primaryEpisode.tap()
        assertNowPlayingOverlay(in: app)
        assertExists(playbackProgress(in: app), named: "Playback Progress control")
    }

    /// Walks the playhead into `range` with the transport skip buttons (30s
    /// back, 15s forward), reading the elapsed label under the slider after
    /// every tap so a dropped tap or playback drift only costs another step.
    /// XCUI's slider adjust lands unpredictably on this slider and its
    /// accessibility value goes stale, so no shot relies on either.
    @MainActor
    private func skipPlayback(into range: ClosedRange<TimeInterval>, named name: String, in app: XCUIApplication) {
        var lastElapsed: TimeInterval?
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.8)
            guard let elapsed = elapsedSeconds(in: app) else {
                break
            }
            lastElapsed = elapsed
            if range.contains(elapsed) {
                return
            }
            tapTransportButton(elapsed > range.upperBound ? "Skip Back 30 Seconds" : "Skip Forward 15 Seconds", in: app)
        }
        XCTFail("Playhead should sit in \(name) (\(range)), got \(String(describing: lastElapsed))")
    }

    /// A skip-button landing inside an auto-skip zone is skipped past the
    /// zone's end, so the transport buttons alone can never park the playhead
    /// inside the sponsor read. The pill's undo is the one seek that lands
    /// inside a zone and plays it through: skip back into the read, let the
    /// auto-skip bounce, then undo it.
    @MainActor
    private func seekIntoSponsorRead(in app: XCUIApplication) {
        let range: ClosedRange<TimeInterval> = 28...55
        let pill = app.buttons["Skipped promo"].firstMatch
        var lastElapsed: TimeInterval?
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.6)
            guard let elapsed = elapsedSeconds(in: app) else {
                break
            }
            lastElapsed = elapsed
            if range.contains(elapsed) {
                return
            }
            tapTransportButton("Skip Back 30 Seconds", in: app)
            if pill.waitForExistence(timeout: 1.5) {
                pill.tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        XCTFail("Playhead should sit in the sponsor read (\(range)), got \(String(describing: lastElapsed))")
    }

    @MainActor
    private func tapTransportButton(_ label: String, in app: XCUIApplication) {
        let button = app.buttons[label].firstMatch
        assertHittable(button, named: label)
        button.tap()
    }

    // The elapsed label is the first m:ss text in the overlay; the remaining
    // label carries a leading minus and never matches. `polling` skips the
    // explicit existence wait.
    @MainActor
    private func elapsedSeconds(in app: XCUIApplication, polling: Bool = false) -> TimeInterval? {
        let predicate = NSPredicate(format: "label MATCHES %@", "^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$")
        let label = nowPlayingOverlay(in: app).staticTexts.matching(predicate).firstMatch
        guard polling ? label.exists : label.waitForExistence(timeout: 2) else {
            return nil
        }
        let parts = label.label.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3:
            return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        case 2:
            return parts[0] * 60 + parts[1]
        default:
            return nil
        }
    }

    @MainActor
    private func pausePlayback(in app: XCUIApplication) {
        let pauseButton = app.buttons["Pause"].firstMatch
        guard pauseButton.waitForExistence(timeout: 3) else {
            return
        }
        pauseButton.tap()
        _ = app.buttons["Play"].firstMatch.waitForExistence(timeout: 3)
    }

    @MainActor
    private func openNowPlayingFromMiniPlayer(in app: XCUIApplication) {
        let miniPlayer = miniPlayer(in: app)
        assertExists(miniPlayer, named: "mini player")
        miniPlayer.tap()
        assertNowPlayingOverlay(in: app)
    }

    @MainActor
    private func openUpNextQueue(in app: XCUIApplication) {
        let upNextButton = app.buttons["Up Next"].firstMatch
        assertExists(upNextButton, named: "Up Next utility button")
        upNextButton.tap()
        assertScreen("Up Next", named: "Up Next sheet", in: app)
        for episodeID in Self.upNextEpisodeIDs {
            assertExists(episodeRow(episodeID, in: app), named: "Up Next row \(episodeID)")
        }
    }

    /// Fully open, the player sits beside its secondary pane, and Up Next is
    /// that pane's mode: selected through the pane's segmented control, its
    /// three queued rows found inside the pane's queue list (below the
    /// control, within its column). No sheet or navigation bar is asked for.
    @MainActor
    private func openUpNextPane(in app: XCUIApplication) {
        let picker = element(withIdentifier: "Now Playing Secondary Pane", in: app)
        assertExists(picker, named: "Now Playing secondary pane control")
        let segment = picker.buttons["Up Next"]
        assertHittable(segment, named: "Up Next segment of the secondary pane")
        segment.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: segment)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, "Up Next segment should be selected")

        // The queue's visible area: the scrolling list in the picker's column,
        // below the picker, inside the Now Playing container.
        let overlay = nowPlayingOverlay(in: app)
        assertExists(overlay, named: "Now Playing container of the secondary pane")
        let picked = picker.frame
        let queueList = overlay.collectionViews.allElementsBoundByIndex.first { list in
            list.exists && list.frame.minY >= picked.maxY - 1 && list.frame.midX > picked.minX
                && list.frame.midX < picked.maxX
        }
        guard let queueList else {
            XCTFail("The secondary pane should show the Up Next queue's list below its control")
            return
        }
        let viewport = queueList.frame.intersection(overlay.frame)
        for episodeID in Self.upNextEpisodeIDs {
            // The Inbox behind the card holds rows with the same identifiers,
            // so only a hittable row wholly inside the queue's viewport counts.
            let rows = queueList.buttons.matching(identifier: "episode-row-\(episodeID)")
            let deadline = Date.now.addingTimeInterval(10)
            var inPane = false
            while !inPane, Date.now < deadline {
                inPane = rows.allElementsBoundByIndex.contains { row in
                    row.exists && row.isHittable && viewport.contains(row.frame)
                }
                if !inPane {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            XCTAssertTrue(inPane, "Up Next row \(episodeID) should be visible in the secondary pane")
        }
    }

    /// Fully open, the skip hero's pane shows what the next skip removes: the
    /// current transcript line with the flagged promo right below it. The
    /// playhead parks on that line while the pane is arranged and plays again
    /// for the frame, so the transport reads as in every other skip shot. The
    /// capture script refuses a second frame under one shot name, so a
    /// playhead that reaches the promo fails the run rather than a retake.
    @MainActor
    private func captureInnerSkipHero(in app: XCUIApplication) {
        parkOnLineBeforePromo(in: app)
        guard let pane = openTranscriptPane(in: app) else {
            return
        }
        assertPromoBelowCurrentLine(in: pane)
        capture("skip") {
            resumePlayback(in: app)
        }
        let elapsed = elapsedSeconds(in: app, polling: true)
        print("skip hero: elapsed after the frame \(String(describing: elapsed)) at \(Date.now)")
        XCTAssertLessThan(
            elapsed ?? .infinity,
            Self.innerSkipPromoStart,
            "The playhead should still be on the line before the promo after the frame"
        )
    }

    /// Pause near the start of the last line before the promo so pane setup
    /// cannot carry playback into the next auto-skip zone. Poll the elapsed
    /// label without an explicit existence wait to preserve the capture margin.
    @MainActor
    private func parkOnLineBeforePromo(in app: XCUIApplication) {
        let overlay = nowPlayingOverlay(in: app)
        let pause = overlay.buttons["Pause"].firstMatch
        assertHittable(pause, named: "Now Playing Pause button")
        let lineStart = Self.innerSkipPauseWindow.lowerBound
        let deadline = Date.now.addingTimeInterval(60)
        var elapsed = elapsedSeconds(in: app, polling: true)
        print("skip hero: elapsed before the wait \(String(describing: elapsed))")
        while (elapsed ?? 0) < lineStart, Date.now < deadline {
            Thread.sleep(forTimeInterval: (elapsed ?? lineStart) < lineStart - 2 ? 1 : 0.05)
            elapsed = elapsedSeconds(in: app, polling: true)
            print("skip hero: elapsed during the wait \(String(describing: elapsed)) at \(Date.now)")
        }
        print("skip hero: elapsed read before the pause \(String(describing: elapsed))")
        guard Date.now < deadline, Self.innerSkipPauseWindow.contains(elapsed ?? .infinity) else {
            XCTFail("Playback should reach \(Self.innerSkipPauseWindow) before the deadline, got \(String(describing: elapsed))")
            return
        }
        pause.tap()
        assertExists(overlay.buttons["Play"].firstMatch, named: "Now Playing Play button once paused")
        let paused = elapsedSeconds(in: app)
        Thread.sleep(forTimeInterval: 1.5)
        let held = elapsedSeconds(in: app)
        print("skip hero: elapsed paused \(String(describing: paused)), 1.5 s later \(String(describing: held))")
        let heldWindow = Self.innerSkipPauseWindow.lowerBound..<Self.innerSkipPromoStart
        for reading in [paused, held] {
            XCTAssertTrue(
                heldWindow.contains(reading ?? .infinity),
                "The paused playhead should read \(heldWindow), got \(String(describing: reading))"
            )
        }
    }

    /// Resume after capture preparation. Avoid explicit waits after the tap
    /// beyond the transport check; the post-frame elapsed assertion rejects a
    /// capture that finishes too late.
    @MainActor
    private func resumePlayback(in app: XCUIApplication) {
        let overlay = nowPlayingOverlay(in: app)
        let play = overlay.buttons["Play"].firstMatch
        assertHittable(play, named: "Now Playing Play button")
        print("skip hero: resuming at \(Date.now)")
        play.tap()
        print("skip hero: resumed at \(Date.now)")
        // "Pause" also shows while buffering or loading, which draw a spinner;
        // only the value says the transport is playing.
        let transport = overlay.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Pause"])).firstMatch
        let deadline = Date.now.addingTimeInterval(1)
        var reading = try? transport.snapshot()
        print("skip hero: transport \(String(describing: reading?.label)) \(String(describing: reading?.value)) at \(Date.now)")
        while !isPlaying(reading), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            reading = try? transport.snapshot()
            print("skip hero: transport \(String(describing: reading?.label)) \(String(describing: reading?.value)) at \(Date.now)")
        }
        XCTAssertTrue(isPlaying(reading), "The transport should read Pause and Playing before the frame")
    }

    @MainActor
    private func isPlaying(_ transport: (any XCUIElementSnapshot)?) -> Bool {
        transport?.label == "Pause" && transport?.value as? String == "Playing"
    }

    /// Fully open, the transcript is the pane's Transcript mode: selected
    /// through the pane's segmented control, its scroller found by the line
    /// the follow-along brings on screen. The viewport is the part of that
    /// scroller below the control and inside the Now Playing container.
    @MainActor
    private func openTranscriptPane(in app: XCUIApplication) -> (scroller: XCUIElement, viewport: CGRect)? {
        let picker = element(withIdentifier: "Now Playing Secondary Pane", in: app)
        assertExists(picker, named: "Now Playing secondary pane control")
        let segment = picker.buttons["Transcript"]
        assertHittable(segment, named: "Transcript segment of the secondary pane")
        segment.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: segment)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, "Transcript segment should be selected")

        let overlay = nowPlayingOverlay(in: app)
        assertExists(overlay, named: "Now Playing container of the secondary pane")
        let currentLine = NSPredicate(format: "label BEGINSWITH %@", Self.innerSkipCurrentLine)
        let deadline = Date.now.addingTimeInterval(10)
        var scrollers = overlay.scrollViews.containing(currentLine).allElementsBoundByIndex
        while scrollers.isEmpty, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            scrollers = overlay.scrollViews.containing(currentLine).allElementsBoundByIndex
        }
        // Prefer the transcript scroller over any enclosing scroll view.
        let scroller = scrollers.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let scroller else {
            print("skip hero: no transcript scroller in\n\(overlay.debugDescription)")
            XCTFail("The secondary pane should show the transcript's line \(Self.innerSkipCurrentLine)")
            return nil
        }
        let picked = picker.frame
        let container = overlay.frame
        let paneArea = CGRect(
            x: container.minX,
            y: picked.maxY,
            width: container.width,
            height: container.maxY - picked.maxY
        )
        let viewport = scroller.frame.intersection(paneArea)
        print("skip hero: picker \(picked), overlay \(container), scroller \(scroller.frame), viewport \(viewport)")
        return (scroller, viewport)
    }

    /// The current line and the flagged promo, both wholly in the pane's
    /// viewport, the promo below the line. When the follow-along leaves the
    /// promo outside, the line is lifted into the viewport's upper half.
    @MainActor
    private func assertPromoBelowCurrentLine(in pane: (scroller: XCUIElement, viewport: CGRect)) {
        let line = transcriptRow(Self.innerSkipCurrentLine, carrying: ["4:26"], in: pane.scroller)
        let promo = transcriptRow(
            Self.innerSkipPromoLine,
            carrying: ["Sponsor segment", "End-of-show promo"],
            in: pane.scroller
        )
        var isShown = waitUntilShown([line, promo], in: pane.viewport)
        if !isShown, line.exists {
            let distance = line.frame.midY - (pane.viewport.minY + pane.viewport.height / 4)
            print("skip hero: scrolling the pane \(distance) pt; line \(line.frame), promo exists \(promo.exists)")
            let start = line.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: -distance))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            isShown = waitUntilShown([line, promo], in: pane.viewport)
        }
        guard isShown else {
            print("skip hero: rows not shown in \(pane.viewport)\n\(pane.scroller.debugDescription)")
            XCTFail("The current line and the flagged promo should both show in the transcript pane")
            return
        }
        print("skip hero: current row \(line.frame) value \(String(describing: line.value))")
        print("skip hero: promo row \(promo.frame) value \(String(describing: promo.value))")
        XCTAssertGreaterThan(promo.frame.minY, line.frame.maxY, "The flagged promo should sit below the current line")
    }

    /// `EpisodeTranscriptLineView`'s button: the segment's text as its label,
    /// the timestamp and any ad description as its value.
    @MainActor
    private func transcriptRow(_ text: String, carrying values: [String], in scroller: XCUIElement) -> XCUIElement {
        let clauses = [NSPredicate(format: "label BEGINSWITH %@", text)]
            + values.map { NSPredicate(format: "value CONTAINS %@", $0) }
        return scroller.buttons.matching(NSCompoundPredicate(andPredicateWithSubpredicates: clauses)).firstMatch
    }

    /// Require complete frame containment before checking for a hittable point.
    @MainActor
    private func waitUntilShown(_ rows: [XCUIElement], in viewport: CGRect) -> Bool {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if rows.allSatisfy({ $0.exists && viewport.contains($0.frame) && $0.isHittable }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    // Play Last keeps the deck's order: the first enqueued row stays first.
    @MainActor
    private func enqueueUpNextEpisodes(in app: XCUIApplication) {
        openInbox(in: app)
        for episodeID in Self.upNextEpisodeIDs {
            let row = episodeRow(episodeID, in: app)
            scrollRootRowUntilHittable(row, in: app)
            row.press(forDuration: 1.2)
            let playLast = app.buttons["Play Last"].firstMatch
            assertExists(playLast, named: "Play Last context action for \(episodeID)")
            playLast.tap()
            _ = playLast.waitForNonExistence(timeout: 2)
        }
    }

    // MARK: - Navigation

    @MainActor
    private func openPrimaryPodcastDetail(in app: XCUIApplication) {
        openLibrary(in: app)
        let primaryPodcast = element(withIdentifier: Self.primarySubscriptionRowIdentifier, in: app)
        scrollRootRowUntilHittable(primaryPodcast, in: app)
        primaryPodcast.tap()
        if rootListIsSidebar {
            // The page's hero fills the detail column; its episodes start below
            // it. The sidebar has an "Orbit Report" text too, so the identifier
            // and the label together name the page.
            let hero = app.staticTexts
                .matching(identifier: "Podcast Hero Header")
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit Report"))
                .firstMatch
            assertExists(hero, named: "primary podcast page hero")
        } else {
            assertExists(app.staticTexts["What the New Telescope Saw First"], named: "primary podcast episode")
        }
    }

    // The Now Playing title opens the current episode's detail and dismisses
    // the card, so the primary episode never needs a row context menu.
    @MainActor
    private func openCurrentEpisodeDetailFromNowPlaying(in app: XCUIApplication) {
        let titleButton = nowPlayingOverlay(in: app).buttons["Now Playing Episode Title"].firstMatch
        assertHittable(titleButton, named: "Now Playing episode title button")
        titleButton.tap()
        assertExists(app.buttons["Play Episode"], named: "episode detail after tapping Now Playing title", timeout: 10)
    }

    // A long press that lands while the list is still settling opens nothing;
    // one retry covers that without hiding a genuinely missing menu.
    @MainActor
    private func openEpisodeDetailFromContextMenu(episodeID: String, in app: XCUIApplication) {
        let row = episodeRow(episodeID, in: app)
        scrollUntilHittable(row, in: app)
        let detailsAction = app.buttons["View Episode Details"].firstMatch
        for attempt in 0..<2 {
            row.press(forDuration: 1.3)
            if detailsAction.waitForExistence(timeout: 4) {
                break
            }
            XCTAssertEqual(attempt, 0, "View Episode Details context action should exist")
            gestureSurface(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        detailsAction.tap()
        assertExists(app.buttons["Play Episode"], named: "episode detail Play button", timeout: 10)
    }

    @MainActor
    private func openTranscriptFromEpisodeDetail(in app: XCUIApplication) {
        let transcriptCard = element(withIdentifier: "Read Transcript", in: app)
        scrollUntilHittable(transcriptCard, in: app)
        transcriptCard.tap()
        assertScreen("Transcript", named: "Transcript screen", in: app, timeout: 10)
    }

    @MainActor
    private func performLibrarySearch(in app: XCUIApplication) {
        openSection("Search", in: app)
        let searchField = app.searchFields.firstMatch
        // iPadOS 27.2 shows the Search tab's field collapsed into its
        // navigation bar's Search button; expand it first.
        let collapsedSearch = app.navigationBars["Search"].buttons["Search"]
        if !searchField.waitForExistence(timeout: 2), collapsedSearch.exists {
            collapsedSearch.tap()
        }
        assertExists(searchField, named: "Search tab field")
        if !searchField.isHittable || app.keyboards.count == 0 {
            searchField.tap()
        }
        searchField.typeText("\(Self.searchQuery)\n")
        for episodeID in Self.searchResultEpisodeIDs {
            assertExists(episodeRow(episodeID, in: app), named: "search result \(episodeID)", timeout: 20)
        }
        _ = element(withIdentifier: "Search Index Updating", in: app).waitForNonExistence(timeout: 10)
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }

    // MARK: - Scrolling

    /// Fully open, the roots are splits: the Inbox and Library lists sit in
    /// the sidebar, and a drag through the window's middle lands on the detail
    /// column. Sidebar rows scroll with an element swipe on the sidebar itself.
    private var rootListIsSidebar: Bool {
        family == .duoInner
    }

    @MainActor
    private func sidebar(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews["Sidebar"].firstMatch
    }

    /// A realized sidebar row can lie outside the window, so its frame is read
    /// before `isHittable` is asked.
    @MainActor
    private func isInSidebarViewport(_ row: XCUIElement, in app: XCUIApplication) -> Bool {
        guard row.exists else {
            return false
        }
        let frame = row.frame
        return sidebar(in: app).frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Whether the row can be used without scrolling back up. Outside a
    /// sidebar that is its existence, as the lazy list drops rows it has left.
    @MainActor
    private func isListed(_ row: XCUIElement, in app: XCUIApplication) -> Bool {
        row.waitForExistence(timeout: 1) && (!rootListIsSidebar || isInSidebarViewport(row, in: app))
    }

    @MainActor
    private func swipeRootListDown(in app: XCUIApplication) {
        guard rootListIsSidebar else {
            swipeContentDown(in: app)
            return
        }
        let list = sidebar(in: app)
        assertExists(list, named: "root list sidebar")
        list.swipeDown(velocity: .slow)
    }

    @MainActor
    private func scrollRootRowUntilHittable(
        _ row: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard rootListIsSidebar else {
            scrollUntilHittable(row, in: app, file: file, line: line)
            return
        }
        let list = sidebar(in: app)
        assertExists(list, named: "root list sidebar", file: file, line: line)
        for _ in 0..<8 {
            if isInSidebarViewport(row, in: app), isClearOfMiniPlayer(row, in: app) {
                return
            }
            list.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTFail("Expected the sidebar row to be hittable after scrolling", file: file, line: line)
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxScrolls: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if element.waitForExistence(timeout: 1), isClearOfMiniPlayer(element, in: app) {
            return
        }

        for _ in 0..<maxScrolls {
            if element.exists, element.isHittable {
                nudgeAboveMiniPlayer(element, in: app)
                if isClearOfMiniPlayer(element, in: app) {
                    return
                }
            }
            swipeContentUp(in: app)
            Thread.sleep(forTimeInterval: 0.8)
            if element.waitForExistence(timeout: 1), isClearOfMiniPlayer(element, in: app) {
                return
            }
        }

        XCTFail("Expected element to be hittable after scrolling", file: file, line: line)
    }

    // A row can report hittable while its lower half sits under the docked
    // tab accessory, and a long press there opens Now Playing (or Up Next,
    // when nothing is playing) instead.
    @MainActor
    private func isClearOfMiniPlayer(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.isHittable else {
            return false
        }
        let accessory = tabAccessory(in: app)
        guard accessory.exists else {
            return true
        }
        return element.frame.maxY <= accessory.frame.minY - 4
    }

    @MainActor
    private func nudgeAboveMiniPlayer(_ element: XCUIElement, in app: XCUIApplication) {
        let accessory = tabAccessory(in: app)
        guard accessory.exists else {
            return
        }
        let overlap = element.frame.maxY - accessory.frame.minY + 24
        guard overlap > 0 else {
            return
        }
        let start = gestureSurface(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let end = start.withOffset(CGVector(dx: 0, dy: -overlap))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Scrolls so `element`'s top edge sits near `targetYFraction` of the
    /// screen: a slow drag by the exact remaining distance, held briefly so
    /// no momentum carries the content past the target.
    @MainActor
    private func scrollToRevealNearTop(
        _ element: XCUIElement,
        in app: XCUIApplication,
        targetYFraction: CGFloat = 0.18
    ) {
        scrollUntilHittable(element, in: app)
        for _ in 0..<3 {
            let surface = gestureSurface(in: app)
            let targetY = surface.frame.minY + surface.frame.height * targetYFraction
            let delta = element.frame.minY - targetY
            guard delta > 24 else {
                return
            }

            let startY = min(0.72, targetYFraction + delta / surface.frame.height)
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = start.withOffset(CGVector(dx: 0, dy: -min(delta, surface.frame.height * 0.5)))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: - Assertions

    // Fails the lane loudly if the seeded analysis did not wire up as exactly
    // three auto-skip zones — the guard behind both the marked Now Playing
    // timeline and the Sound Lab shot.
    @MainActor
    private func assertSeededSkipZonesMarked(in app: XCUIApplication) {
        let control = app.descendants(matching: .any)["Skip Promos & Ads"].firstMatch
        assertExists(control, named: "Skip Promos & Ads control")
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "3 zones marked."),
            object: control
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Skip Promos & Ads control should report \"3 zones marked.\" from the seeded analysis, got \(String(describing: control.value))"
        )
    }

    @MainActor
    private func assertCompletedTranscriptReady(in app: XCUIApplication) {
        let control = app.descendants(matching: .any)["Show Transcript"].firstMatch
        assertExists(control, named: "Show Transcript control")
        XCTAssertTrue(control.isEnabled, "Show Transcript control should be ready to open")
    }

    @MainActor
    private func assertNowPlayingOverlay(in app: XCUIApplication) {
        assertExists(nowPlayingOverlay(in: app), named: "Now Playing overlay")
    }

    // MARK: - Now Playing gestures

    @MainActor
    private func revealNowPlayingSoundLab(in app: XCUIApplication) {
        let artwork = nowPlayingArtwork(in: app)
        assertExists(artwork, named: "Now Playing artwork before Sound Lab reveal")
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.52))
        let end = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.48))
        start.press(forDuration: 0.10, thenDragTo: end)
    }

    // MARK: - Elements

    @MainActor
    private func sponsorTranscriptRow(in app: XCUIApplication) -> XCUIElement {
        let sponsor = "Bottomless Mug Coffee Co."
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", sponsor, sponsor)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func element(withIdentifier identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func episodeRow(_ episodeID: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "episode-row-\(episodeID)").firstMatch
    }

    @MainActor
    private func miniPlayer(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Open Now Playing"].firstMatch
    }

    @MainActor
    private func tabAccessory(in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Open Now Playing", "Open Up Next"]))
            .firstMatch
    }

    // Stack-based sections retain pushed pages, so return to their root list.
    // In a split, the sidebar root stays visible beside its selected detail.
    @MainActor
    private func openLibrary(in app: XCUIApplication) {
        openSectionRoot("Library", in: app)
    }

    @MainActor
    private func openInbox(in app: XCUIApplication) {
        openSectionRoot("Inbox", in: app)
    }

    @MainActor
    private func openSectionRoot(_ title: String, in app: XCUIApplication) {
        openSection(title, in: app)
        for _ in 0..<4 {
            if waitForScreen(title, in: app, timeout: 1) {
                return
            }
            var backButton = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            if !backButton.exists, isSectionRail(in: app) {
                backButton = app.buttons["BackButton"].firstMatch
            }
            guard backButton.exists else {
                break
            }
            backButton.tap()
        }
        assertScreen(title, named: "\(title) root screen", in: app, timeout: 3)
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

private struct ScreenshotFamilyError: Error, CustomStringConvertible {
    let description: String
}
