import XCTest

final class NotificationSecurityUITests: XCTestCase {
    private static let notificationSyncFeedURLKey = "OPENCAST_NOTIFICATION_SYNC_FEED_URL"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPhysicalDeviceNotificationSecurityDiagnosticPasses() throws {
        try skipIfRunningOnSimulator()

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-light-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        app.launch()

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Run Check"], in: app).tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Rejected Proof, goodbye world", in: app, timeout: 30))
        XCTAssertTrue(waitForDiagnosticText(containing: "Valid Proof, hello world", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "App Attest, Supported", in: app, timeout: 15))
    }

    @MainActor
    func testPhysicalDeviceNotificationRegistrationDiagnosticSendsPush() throws {
        try skipIfRunningOnSimulator()

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

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-light-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        app.launch()

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Register and Send Test Push"], in: app).tap()
        app.tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Permission, Authorized", in: app, timeout: 30))
        XCTAssertTrue(waitForDiagnosticText(containing: "APNs Registration, Registered", in: app, timeout: 60))
        XCTAssertTrue(waitForDiagnosticText(containing: "Worker Registration, registered", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Test Push, sent", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "APNs Status, 200", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Device Delivery, Received", in: app, timeout: 90))
    }

    @MainActor
    func testPhysicalDeviceNotificationSubscriptionSyncDiagnosticPasses() throws {
        try skipIfRunningOnSimulator()

        let app = makePhysicalDiagnosticApp()
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = try Self.notificationSyncFeedURLOrSkip()
        app.launch()

        subscribeToSeedFeed(in: app)

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Sync Notification Subscriptions"], in: app).tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Sync, synced", in: app, timeout: 90))
        assertSingleFeedEnqueuedOrAccepted(in: app)
    }

    @MainActor
    func testPhysicalDeviceReleaseOnboardingEnableNotificationsPasses() throws {
        try skipIfRunningOnSimulator()

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

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-onboarding",
            "--opencast-seed-ui-library",
            "--opencast-force-light-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_ONBOARDING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to opencast!"].waitForExistence(timeout: 20))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 10))
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts["Find Podcasts"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        // The transcription step is conditional: Apple-capable
        // devices show the Apple setup page or no page at all; only
        // Apple-unavailable devices show the Tiny Whisper page.
        let notificationsPage = app.staticTexts["New Episode Alerts"]
        if !notificationsPage.waitForExistence(timeout: 5) {
            let transcriptionStepShown = app.staticTexts["On-Device Transcription"].waitForExistence(timeout: 5)
                || app.staticTexts["Tiny Whisper Model"].waitForExistence(timeout: 5)
            XCTAssertTrue(transcriptionStepShown, "Expected a transcription setup step before notifications")
            app.buttons["Skip"].tap()
        }
        XCTAssertTrue(notificationsPage.waitForExistence(timeout: 10))

        app.buttons["Enable Notifications"].tap()
        app.tap()

        XCTAssertTrue(
            staticText(containing: "Notifications are on", in: app).waitForExistence(timeout: 120)
                || staticText(containing: "synced", in: app).waitForExistence(timeout: 1),
            "Notification onboarding should complete production App Attest/APNs registration without surfacing the DeviceCheck stale-key error."
        )
        XCTAssertFalse(staticText(containing: "com.apple.devicecheck.error", in: app).exists)
    }

    @MainActor
    func testPhysicalDeviceNotificationLookFixtureScreenshots() throws {
        try skipIfRunningOnSimulator()

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

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-light-mode",
            "--opencast-schedule-notification-look-fixture",
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        app.launchEnvironment["OPENCAST_SCHEDULE_NOTIFICATION_LOOK_FIXTURE"] = "1"
        app.launch()
        app.tap()

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        Thread.sleep(forTimeInterval: 5)
        settleSpringBoardNotificationSurface(in: springboard)
        let notification = try waitForSpringBoardNotification(
            containing: "866: Very Nice",
            in: springboard,
            timeout: 30
        )
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 2))
        attachSmokeScreenshot(named: "notification_look_collapsed")

        notification.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 2))
        attachSmokeScreenshot(named: "notification_look_expanded")
    }

    @MainActor
    func testSimulatorAdFreePassCompletionNotificationLookFixtureScreenshots() throws {
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

        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-light-mode",
            "--opencast-schedule-adfreepass-notification-look-fixture",
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        app.launchEnvironment["OPENCAST_SCHEDULE_ADFREEPASS_NOTIFICATION_LOOK_FIXTURE"] = "1"
        app.launch()
        app.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowButton = springboard.buttons["Allow"]
        if allowButton.waitForExistence(timeout: 5) {
            allowButton.tap()
        }

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        settleSpringBoardNotificationSurface(in: springboard)
        let notification = try waitForSpringBoardNotification(
            containing: "ad breaks",
            in: springboard,
            timeout: 30
        )
        XCTAssertTrue(notification.exists)
        XCTAssertNotEqual(app.state, .runningForeground)
        attachSmokeScreenshot(named: "adfreepass_notification_look_collapsed")

        notification.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(
            staticText(containing: "couldn't be analyzed", in: springboard).waitForExistence(timeout: 5),
            "Expanded ad-free-pass notification should render the failures body line."
        )
        XCTAssertNotEqual(app.state, .runningForeground)
        attachSmokeScreenshot(named: "adfreepass_notification_look_expanded")
    }

    private static func notificationSyncFeedURLOrSkip() throws -> String {
        guard let feedURL = ProcessInfo.processInfo.environment[notificationSyncFeedURLKey],
              !feedURL.isEmpty
        else {
            throw XCTSkip("Set \(notificationSyncFeedURLKey) to a public RSS feed before running this proof.")
        }

        return feedURL
    }

    private func skipIfRunningOnSimulator() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Production App Attest/APNs notification diagnostics require a physical device.")
        #endif
    }

    @MainActor
    private func makePhysicalDiagnosticApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--opencast-ui-testing",
            "--opencast-force-light-mode"
        ]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_LIGHT_MODE"] = "1"
        return app
    }

    @MainActor
    private func subscribeToSeedFeed(in app: XCUIApplication) {
        subscribeToFeed(in: app, title: "The Seed Podcast")
    }

    @MainActor
    private func subscribeToFeed(in app: XCUIApplication, title: String, timeout: TimeInterval = 45) {
        openLibrary(in: app)
        tapAddPodcastButton(in: app)
        scrollUntilHittable(app.buttons["Subscribe"], in: app).tap()

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: timeout))
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        openSection("Settings", in: app)
    }

    @MainActor
    private func assertSingleFeedEnqueuedOrAccepted(in app: XCUIApplication) {
        XCTAssertTrue(waitForDiagnosticText(containing: "Rejected, 0", in: app, timeout: 15))
        // Unknown feeds enqueue without fetching in the sync request. The
        // queued engine establishes the baseline before sending any releases.
        let accepted = staticText(containing: "Accepted, 1", in: app).exists
        let pending = staticText(containing: "Pending, 1", in: app).exists
        XCTAssertNotEqual(accepted, pending, "Exactly one feed must be accepted or pending its first scan")
    }

    @MainActor
    private func openDiagnostics(in app: XCUIApplication) {
        if diagnosticsContentExists(in: app) {
            return
        }

        openSettings(in: app)
        if diagnosticsContentExists(in: app) {
            return
        }

        let diagnosticsRow = app.buttons["Settings Row Diagnostics"].firstMatch
        if diagnosticsRow.waitForExistence(timeout: 2) {
            var swipes = 0
            while !diagnosticsRow.isHittable, swipes < 4 {
                swipeUpInDetailColumn(in: app)
                swipes += 1
            }
            if diagnosticsRow.isHittable {
                diagnosticsRow.tap()
                return
            }
        }

        if tapDiagnosticsButtonIfHittable(in: app) {
            return
        }

        for _ in 0..<4 {
            swipeDownInDetailColumn(in: app)
            if diagnosticsContentExists(in: app) || tapDiagnosticsButtonIfHittable(in: app) {
                return
            }
        }

        for _ in 0..<10 {
            swipeUpInDetailColumn(in: app)
            if diagnosticsContentExists(in: app) || tapDiagnosticsButtonIfHittable(in: app) {
                return
            }
        }

        XCTFail("Diagnostics navigation item should exist or diagnostics content should already be open")
    }

    @MainActor
    private func diagnosticsContentExists(in app: XCUIApplication) -> Bool {
        app.buttons["Run Check"].exists
            || app.buttons["Register and Send Test Push"].exists
            || app.buttons["Sync Notification Subscriptions"].exists
    }

    @MainActor
    private func tapDiagnosticsButtonIfHittable(in app: XCUIApplication) -> Bool {
        let diagnosticsButton = app.buttons["Diagnostics"]
        guard diagnosticsButton.waitForExistence(timeout: 1), diagnosticsButton.isHittable else {
            return false
        }

        diagnosticsButton.tap()
        return true
    }

    @MainActor
    private func openLibrary(in app: XCUIApplication) {
        openSection("Library", in: app)
    }

    @MainActor
    private func tapAddPodcastButton(in app: XCUIApplication) {
        let libraryAddButton = app.navigationBars["Library"].buttons["Add"]
        if libraryAddButton.waitForExistence(timeout: 2) {
            libraryAddButton.tap()
            return
        }

        let rootAddButton = app.navigationBars["opencast"].buttons["Add"]
        if rootAddButton.waitForExistence(timeout: 2) {
            rootAddButton.tap()
            return
        }

        let addButton = app.buttons["Add"].firstMatch
        if addButton.waitForExistence(timeout: 2) {
            addButton.tap()
            return
        }

        XCTFail("Add Podcast button should exist")
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 8
    ) -> XCUIElement {
        if element.waitForExistence(timeout: 5), element.isHittable {
            return element
        }

        for _ in 0..<maxSwipes {
            swipeUpInDetailColumn(in: app)
            if element.waitForExistence(timeout: 1), element.isHittable {
                return element
            }
        }

        XCTFail("Expected \(element) to become hittable")
        return element
    }

    @MainActor
    private func swipeUpInDetailColumn(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.84))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.24))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func swipeDownInDetailColumn(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.24))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.84))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func staticText(containing label: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func waitForDiagnosticText(
        containing label: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if staticText(containing: label, in: app).waitForExistence(timeout: 1) {
                return true
            }

            swipeUpInDetailColumn(in: app)
            if staticText(containing: label, in: app).waitForExistence(timeout: 1) {
                return true
            }

            Thread.sleep(forTimeInterval: 1)
        }

        return staticText(containing: label, in: app).waitForExistence(timeout: 1)
    }

}
