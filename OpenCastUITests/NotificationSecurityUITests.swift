import XCTest

final class NotificationSecurityUITests: XCTestCase {
    private static let notificationSyncFeedURLKey = "OPENCAST_NOTIFICATION_SYNC_FEED_URL"
    private static let notificationFixtureFeedBaseURLKey = "OPENCAST_NOTIFICATION_FIXTURE_FEED_BASE_URL"
    private static let adminPollURLKey = "OPENCAST_NOTIFICATION_ADMIN_POLL_URL"

    private struct NotificationLookFixtureTimeout: Error, CustomStringConvertible {
        var label: String

        var description: String {
            "Notification look fixture containing \"\(label)\" did not appear on SpringBoard before the timeout."
        }
    }

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
    func testPhysicalDeviceNotificationSubscriptionSyncAndPollDiagnosticsPass() throws {
        try skipIfRunningOnSimulator()

        let app = makePhysicalDiagnosticApp()
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = try Self.notificationSyncFeedURLOrSkip()
        app.launch()

        subscribeToSeedFeed(in: app)

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Sync Notification Subscriptions"], in: app).tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Sync, synced", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Accepted, 1", in: app, timeout: 15))
        XCTAssertTrue(waitForDiagnosticText(containing: "Rejected, 0", in: app, timeout: 15))

        scrollUntilHittable(app.buttons["Poll Synced Feeds"], in: app).tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Poll, polled", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Feeds Polled, 1", in: app, timeout: 15))
        XCTAssertFalse(staticText(containing: "missing_redirect_location", in: app).exists)
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
        XCTAssertTrue(app.staticTexts["Get New Episode Alerts"].waitForExistence(timeout: 10))

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
            containing: "A Paleontology Of The Future",
            in: springboard,
            timeout: 30
        )
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 2))
        XCTAssertNotEqual(app.state, .runningForeground)
        attachScreen(named: "notification_look_collapsed")

        notification.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 2))
        XCTAssertNotEqual(app.state, .runningForeground)
        attachScreen(named: "notification_look_expanded")
    }

    @MainActor
    func testPhysicalDeviceTemporaryFeedSendsFreshEpisodeAndDedupes() throws {
        try skipIfRunningOnSimulator()

        let runID = "proof-\(Int(Date().timeIntervalSince1970))"
        let rolloverTime = Date().timeIntervalSince1970 + 180
        let feedURL = try Self.notificationFixtureFeedURL(runID: runID, rolloverTime: rolloverTime)

        XCTAssertLessThan(
            Date().timeIntervalSince1970,
            rolloverTime - 20,
            "Fixture rollover must still be in the future when the baseline sync starts."
        )

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

        let app = makePhysicalDiagnosticApp()
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = feedURL
        app.launch()

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Register and Send Test Push"], in: app).tap()
        app.tap()

        XCTAssertTrue(staticText(containing: "Worker Registration, registered", in: app).waitForExistence(timeout: 90))
        XCTAssertTrue(staticText(containing: "APNs Status, 200", in: app).waitForExistence(timeout: 90))

        subscribeToFeed(in: app, title: "OpenCast Notification Fixture")

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Sync Notification Subscriptions"], in: app).tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Sync, synced", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Accepted, 1", in: app, timeout: 15))
        XCTAssertTrue(waitForDiagnosticText(containing: "Rejected, 0", in: app, timeout: 15))

        waitForFixtureRollover(rolloverTime)

        scrollUntilHittable(app.buttons["Poll Synced Feeds"], in: app).tap()
        XCTAssertTrue(waitForDiagnosticText(containing: "Poll, polled", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Feeds Changed, 1", in: app, timeout: 15))
        XCTAssertTrue(waitForDiagnosticText(containing: "Notifications Attempted, 1", in: app, timeout: 15))
        XCTAssertTrue(waitForDiagnosticText(containing: "APNs 200, 1", in: app, timeout: 15))
        XCTAssertFalse(staticText(containing: "missing_redirect_location", in: app).exists)

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Poll Synced Feeds"], in: app).tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Poll, polled", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Notifications Attempted, 0", in: app, timeout: 15))
        XCTAssertFalse(staticText(containing: "missing_redirect_location", in: app).exists)
    }

    #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
    @MainActor
    func testPhysicalDeviceProdStagingFixturePushArrivesWhileBackgroundedAndDedupes() async throws {
        try skipIfRunningOnSimulator()

        let adminToken = try Self.prodStagingAdminTokenOrSkip()
        let runID = "prod-staging-\(Int(Date().timeIntervalSince1970))"
        let rolloverTime = Date().timeIntervalSince1970 + 180
        let feedURL = try Self.notificationFixtureFeedURL(runID: runID, rolloverTime: rolloverTime)

        XCTAssertLessThan(
            Date().timeIntervalSince1970,
            rolloverTime - 20,
            "Fixture rollover must still be in the future when the baseline sync starts."
        )

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

        let app = makePhysicalDiagnosticApp()
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = feedURL
        app.launch()

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Register and Send Test Push"], in: app).tap()
        app.tap()

        XCTAssertTrue(staticText(containing: "Worker Registration, registered", in: app).waitForExistence(timeout: 90))
        XCTAssertTrue(staticText(containing: "APNs Status, 200", in: app).waitForExistence(timeout: 90))

        subscribeToFeed(in: app, title: "OpenCast Notification Fixture")

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Sync Notification Subscriptions"], in: app).tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Sync, synced", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Accepted, 1", in: app, timeout: 15))
        XCTAssertTrue(waitForDiagnosticText(containing: "Rejected, 0", in: app, timeout: 15))

        XCUIDevice.shared.press(.home)
        waitForFixtureRollover(rolloverTime)

        let firstPoll = try await Self.triggerProdStagingAdminPoll(feedURL: feedURL, adminToken: adminToken)
        XCTAssertEqual(firstPoll.message, "polled")
        XCTAssertEqual(firstPoll.feedsPolled, 1)
        XCTAssertEqual(firstPoll.feedsChanged, 1)
        XCTAssertEqual(firstPoll.notificationsAttempted, 1)
        XCTAssertEqual(firstPoll.apns200Count, 1)
        XCTAssertEqual(firstPoll.dedupedCount, 0)
        XCTAssertNil(firstPoll.firstError)

        let secondPoll = try await Self.triggerProdStagingAdminPoll(feedURL: feedURL, adminToken: adminToken)
        XCTAssertEqual(secondPoll.message, "polled")
        XCTAssertEqual(secondPoll.feedsPolled, 1)
        XCTAssertEqual(secondPoll.notificationsAttempted, 0)
        XCTAssertEqual(secondPoll.apns200Count, 0)
        XCTAssertNil(secondPoll.firstError)
    }

    @MainActor
    func testPhysicalDeviceProdStagingFixtureManualNotificationTapRoutesToFreshEpisode() async throws {
        try skipIfRunningOnSimulator()

        guard ProcessInfo.processInfo.environment["OPENCAST_MANUAL_NOTIFICATION_TAP_PROOF"] == "1" else {
            throw XCTSkip(
                "Set OPENCAST_MANUAL_NOTIFICATION_TAP_PROOF=1 and tap the delivered notification on the iPad to run this manual proof."
            )
        }

        let adminToken = try Self.prodStagingAdminTokenOrSkip()
        let runID = "manual-tap-\(Int(Date().timeIntervalSince1970))"
        let rolloverTime = Date().timeIntervalSince1970 + 180
        let feedURL = try Self.notificationFixtureFeedURL(runID: runID, rolloverTime: rolloverTime)

        XCTAssertLessThan(
            Date().timeIntervalSince1970,
            rolloverTime - 20,
            "Fixture rollover must still be in the future when the baseline sync starts."
        )

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

        let app = makePhysicalDiagnosticApp()
        app.launchEnvironment["OPENCAST_DEFAULT_FEED_URL"] = feedURL
        app.launch()

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Register and Send Test Push"], in: app).tap()
        app.tap()

        XCTAssertTrue(staticText(containing: "Worker Registration, registered", in: app).waitForExistence(timeout: 90))
        XCTAssertTrue(staticText(containing: "APNs Status, 200", in: app).waitForExistence(timeout: 90))

        subscribeToFeed(in: app, title: "OpenCast Notification Fixture")

        openDiagnostics(in: app)
        scrollUntilHittable(app.buttons["Sync Notification Subscriptions"], in: app).tap()

        XCTAssertTrue(waitForDiagnosticText(containing: "Sync, synced", in: app, timeout: 90))
        XCTAssertTrue(waitForDiagnosticText(containing: "Accepted, 1", in: app, timeout: 15))
        XCTAssertTrue(waitForDiagnosticText(containing: "Rejected, 0", in: app, timeout: 15))

        XCUIDevice.shared.press(.home)
        waitForFixtureRollover(rolloverTime)

        let firstPoll = try await Self.triggerProdStagingAdminPoll(feedURL: feedURL, adminToken: adminToken)
        XCTAssertEqual(firstPoll.message, "polled")
        XCTAssertEqual(firstPoll.feedsPolled, 1)
        XCTAssertEqual(firstPoll.feedsChanged, 1)
        XCTAssertEqual(firstPoll.notificationsAttempted, 1)
        XCTAssertEqual(firstPoll.apns200Count, 1)
        XCTAssertEqual(firstPoll.dedupedCount, 0)
        XCTAssertNil(firstPoll.firstError)

        if ProcessInfo.processInfo.environment["OPENCAST_AUTOMATED_NOTIFICATION_TAP_PROOF"] == "1" {
            _ = tapFreshFixtureNotificationFromSpringBoard(for: app, timeout: 45)
        }

        guard app.wait(for: .runningForeground, timeout: 240) else {
            XCTFail("Tap the delivered Fresh Fixture Episode notification on Connor's iPad before the timeout.")
            return
        }

        XCTAssertTrue(
            waitForDiagnosticText(containing: "Fresh Fixture Episode", in: app, timeout: 90),
            "Manual notification tap should route to the fresh episode detail."
        )

        let secondPoll = try await Self.triggerProdStagingAdminPoll(feedURL: feedURL, adminToken: adminToken)
        XCTAssertEqual(secondPoll.message, "polled")
        XCTAssertEqual(secondPoll.feedsPolled, 1)
        XCTAssertEqual(secondPoll.notificationsAttempted, 0)
        XCTAssertEqual(secondPoll.apns200Count, 0)
        XCTAssertNil(secondPoll.firstError)
    }
    #endif

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
    private func subscribeToFeed(in app: XCUIApplication, title: String) {
        openLibrary(in: app)
        tapAddPodcastButton(in: app)
        scrollUntilHittable(app.buttons["Subscribe"], in: app).tap()

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 45))
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        if let tabButton = visibleTabButton("Settings", in: app) {
            tabButton.tap()
            return
        }

        let sidebarButton = app.collectionViews["Sidebar"].buttons["Settings"].firstMatch
        if sidebarButton.waitForExistence(timeout: 5) {
            sidebarButton.tap()
            return
        }

        let sidebarCell = app.cells.containing(.staticText, identifier: "Settings").element
        if sidebarCell.waitForExistence(timeout: 5) {
            sidebarCell.tap()
            return
        }

        XCTFail("Settings navigation item should exist")
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
            || app.buttons["Poll Synced Feeds"].exists
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
        if let tabButton = visibleTabButton("Library", in: app) {
            tabButton.tap()
            return
        }

        let sidebarButton = app.buttons["Library"]
        if sidebarButton.waitForExistence(timeout: 5) {
            sidebarButton.tap()
            return
        }

        let sidebarCell = app.cells.containing(.staticText, identifier: "Library").element
        if sidebarCell.waitForExistence(timeout: 5) {
            sidebarCell.tap()
            return
        }

        XCTFail("Library navigation item should exist")
    }

    @MainActor
    private func visibleTabButton(
        _ title: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let tabButton = app.tabBars.buttons[title]
        if tabButton.waitForExistence(timeout: 2) {
            return tabButton
        }

        guard app.tabBars.firstMatch.waitForExistence(timeout: 1) else {
            return nil
        }

        app.swipeDown()
        return tabButton.waitForExistence(timeout: 2) ? tabButton : nil
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

    @MainActor
    private func waitForFixtureRollover(_ rolloverTime: TimeInterval) {
        let secondsUntilRollover = rolloverTime - Date().timeIntervalSince1970
        guard secondsUntilRollover > 0 else {
            return
        }

        Thread.sleep(forTimeInterval: secondsUntilRollover + 5)
    }

    @MainActor
    private func tapFreshFixtureNotificationFromSpringBoard(
        for app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        var didOpenNotificationCenter = false

        while Date() < deadline {
            if tapSpringBoardNotificationSurface(in: springboard),
               app.wait(for: .runningForeground, timeout: 5) {
                return true
            }

            if tapSpringBoardText(containing: "Fresh Fixture Episode", in: springboard),
               app.wait(for: .runningForeground, timeout: 5) {
                return true
            }

            tapTopBannerCoordinate(in: springboard)
            if app.wait(for: .runningForeground, timeout: 5) {
                return true
            }

            if !didOpenNotificationCenter {
                openNotificationCenter(in: springboard)
                didOpenNotificationCenter = true
            } else {
                Thread.sleep(forTimeInterval: 1)
            }
        }

        return false
    }

    @MainActor
    private func tapSpringBoardNotificationSurface(in springboard: XCUIApplication) -> Bool {
        let predicate = NSPredicate(format: "identifier == %@ OR label CONTAINS %@", "NotificationShortLookView", "Fresh Fixture Episode")
        let element = springboard.descendants(matching: .any).matching(predicate).firstMatch
        guard element.waitForExistence(timeout: 1) else {
            return false
        }

        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    @MainActor
    private func waitForSpringBoardNotification(
        containing label: String,
        in springboard: XCUIApplication,
        timeout: TimeInterval
    ) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var didOpenNotificationCenter = false
        let notificationPredicate = NSPredicate(
            format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            "NotificationShortLookView",
            label,
            label
        )
        let textPredicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", label, label)

        while Date() < deadline {
            let notification = springboard.descendants(matching: .any).matching(notificationPredicate).firstMatch
            if notification.waitForExistence(timeout: 1) {
                return notification
            }

            let text = springboard.descendants(matching: .any).matching(textPredicate).firstMatch
            if text.waitForExistence(timeout: 1) {
                return text
            }

            if !didOpenNotificationCenter {
                openNotificationCenter(in: springboard)
                didOpenNotificationCenter = true
            } else {
                Thread.sleep(forTimeInterval: 1)
            }
        }

        throw NotificationLookFixtureTimeout(label: label)
    }

    @MainActor
    private func attachScreen(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tapSpringBoardText(containing label: String, in springboard: XCUIApplication) -> Bool {
        let element = staticText(containing: label, in: springboard)
        guard element.waitForExistence(timeout: 1) else {
            return false
        }

        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    @MainActor
    private func tapTopBannerCoordinate(in springboard: XCUIApplication) {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10)).tap()
    }

    @MainActor
    private func openNotificationCenter(in springboard: XCUIApplication) {
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    private func settleSpringBoardNotificationSurface(in springboard: XCUIApplication) {
        for _ in 0..<3 {
            openNotificationCenter(in: springboard)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func notificationSyncFeedURLOrSkip() throws -> String {
        guard let feedURL = ProcessInfo.processInfo.environment[notificationSyncFeedURLKey],
              !feedURL.isEmpty
        else {
            throw XCTSkip("Set \(notificationSyncFeedURLKey) to a public RSS feed before running this proof.")
        }

        return feedURL
    }

    private static func notificationFixtureFeedURL(
        runID: String,
        rolloverTime: TimeInterval
    ) throws -> String {
        guard let baseURL = ProcessInfo.processInfo.environment[notificationFixtureFeedBaseURLKey],
              var components = URLComponents(string: baseURL),
              !baseURL.isEmpty
        else {
            throw XCTSkip("Set \(notificationFixtureFeedBaseURLKey) to a self-hosted rollover fixture feed before running this proof.")
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "run", value: runID))
        queryItems.append(URLQueryItem(name: "rollover", value: String(Int(rolloverTime))))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw XCTSkip("\(notificationFixtureFeedBaseURLKey) must be an absolute URL.")
        }

        return url.absoluteString
    }

    #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
    private static func triggerProdStagingAdminPoll(
        feedURL: String,
        adminToken: String
    ) async throws -> AdminPollResponse {
        var request = URLRequest(url: try prodStagingAdminPollURLOrSkip())
        request.httpMethod = "POST"
        request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(AdminPollPayload(feedURL: feedURL))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AdminPollError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw XCTSkip("Prod-staging admin poll endpoint is disabled by default. Temporarily enable ADMIN_TEST_ENDPOINTS_ENABLED for a proof run, then disable and redeploy it. Response: \(body)")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AdminPollError.http(statusCode: httpResponse.statusCode, body: body)
        }

        return try JSONDecoder().decode(AdminPollResponse.self, from: data)
    }

    private static func prodStagingAdminPollURLOrSkip() throws -> URL {
        guard let urlString = ProcessInfo.processInfo.environment[adminPollURLKey],
              let url = URL(string: urlString),
              !urlString.isEmpty
        else {
            throw XCTSkip("Set \(adminPollURLKey) to your self-hosted admin poll endpoint before running this proof.")
        }

        return url
    }

    private static func prodStagingAdminTokenOrSkip() throws -> String {
        guard let token = ProcessInfo.processInfo.environment["OPENCAST_NOTIFICATION_ADMIN_TOKEN"],
              !token.isEmpty
        else {
            throw XCTSkip("OPENCAST_NOTIFICATION_ADMIN_TOKEN is absent; skipping prod-staging admin endpoint proof.")
        }

        return token
    }

    private struct AdminPollPayload: Encodable, Sendable {
        let feedURL: String

        enum CodingKeys: String, CodingKey {
            case feedURL = "feed_url"
        }
    }

    private struct AdminPollResponse: Decodable, Sendable {
        let message: String
        let feedsPolled: Int
        let feedsChanged: Int
        let notificationsAttempted: Int
        let apns200Count: Int
        let dedupedCount: Int
        let firstError: String?

        enum CodingKeys: String, CodingKey {
            case message
            case feedsPolled = "feeds_polled"
            case feedsChanged = "feeds_changed"
            case notificationsAttempted = "notifications_attempted"
            case apns200Count = "apns_200_count"
            case dedupedCount = "deduped_count"
            case firstError = "first_error"
        }
    }

    private enum AdminPollError: Error, CustomStringConvertible, Sendable {
        case invalidResponse
        case http(statusCode: Int, body: String)

        var description: String {
            switch self {
            case .invalidResponse:
                "Admin poll returned a non-HTTP response."
            case .http(let statusCode, let body):
                "Admin poll failed with HTTP \(statusCode): \(body)"
            }
        }
    }
    #endif

}
