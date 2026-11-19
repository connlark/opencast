import XCTest

/// The Up Next Tab switch (Settings › Look & Feel): off by default; on, Up
/// Next takes the place of Settings on the tab bar and Settings opens from a
/// button in the Library's navigation bar. The flips both ways, the queue's
/// doors, a row in the tab, launch, and one writer that opens a Settings
/// screen. Pinned iPhone; the iPad's test is in `OpenCastPadUITests`.
final class UpNextTabSwitchUITests: XCTestCase {
    private static let queuedEpisodeRowIdentifiers = (1...3).map {
        "episode-row-ui-test-queued-episode-\($0)"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOffByDefaultKeepsTheSettingsTabAndNoLibraryButton() throws {
        let app = makeApp()
        app.launch()

        assertSectionItemExists("Settings", named: "Settings tab", in: app)
        XCTAssertFalse(app.tabBars.buttons["Up Next"].exists, "No Up Next tab with the switch off")
        openSection("Library", in: app)
        assertScreen("Library", named: "Library", in: app)
        assertDoesNotExist(librarySettingsButton(in: app), named: "Library Settings button with the switch off")

        openSettingsScreen("Look & Feel", in: app)
        let toggle = upNextTabToggle(in: app)
        assertExists(toggle, named: "Up Next Tab toggle")
        assertToggle(toggle, isOn: false)
        assertExists(
            app.staticTexts["Up Next takes the place of Settings on the tab bar. Settings opens from the Library."],
            named: "Up Next Tab footer"
        )
    }

    @MainActor
    func testFlippingOnKeepsLookAndFeelInFrontUnderTheLibrary() throws {
        let app = makeApp()
        app.launch()

        openSettingsScreen("Look & Feel", in: app)
        tapToggle(upNextTabToggle(in: app), to: true)

        XCTAssertTrue(waitForNavigationItem("Up Next", toExist: true, in: app), "Up Next joins the tab bar")
        XCTAssertTrue(waitForNavigationItem("Settings", toExist: false, in: app), "Settings leaves the tab bar")
        XCTAssertFalse(app.tabBars.buttons["More"].exists, "The bar never folds into More")
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected, "The Library holds the screen")
        assertScreen("Look & Feel", named: "Look & Feel, still in front", in: app)
        assertToggle(upNextTabToggle(in: app), isOn: true)

        tapBackButton(in: app)
        assertScreen("Settings", named: "the Settings hub under Look & Feel", in: app)
        tapBackButton(in: app)
        assertScreen("Library", named: "the Library under the hub", in: app)
        assertExists(librarySettingsButton(in: app), named: "Library Settings button")
    }

    @MainActor
    func testUpNextTabShowsTheQueueAndARowPlaysInPlace() throws {
        let app = makeApp(isSwitchOn: true, seedsQueue: true)
        app.launch()

        openSection("Up Next", in: app)
        assertScreen("Up Next", named: "the Up Next tab", in: app)
        let rows = Self.queuedEpisodeRowIdentifiers.map { visibleRow($0, in: app) }
        for (index, row) in rows.enumerated() {
            assertExists(row, named: "queued episode \(index + 1) in the tab")
        }
        assertExists(app.buttons["Open Up Next"], named: "the queue head accessory before playing")

        rows[1].tap()

        assertExists(app.buttons["Open Now Playing"], named: "the mini player after a row plays", timeout: 10)
        XCTAssertFalse(nowPlayingCardIsPresented(in: app), "A row plays without presenting Now Playing")
        assertScreen("Up Next", named: "the Up Next tab, still in front", in: app)
        XCTAssertTrue(app.tabBars.buttons["Up Next"].isSelected, "The Up Next tab stays selected")
    }

    @MainActor
    func testLibraryRowAndAccessorySelectTheTab() throws {
        let app = makeApp(isSwitchOn: true, seedsQueue: true)
        app.launch()

        let accessory = app.buttons["Open Up Next"]
        assertHittable(accessory, named: "the queue head accessory")
        accessory.tap()
        XCTAssertTrue(waitForSelection("Up Next", in: app), "The accessory selects the Up Next tab")
        assertScreen("Up Next", named: "the Up Next tab from the accessory", in: app)
        XCTAssertFalse(app.buttons["Done"].exists, "No queue sheet")

        openSection("Library", in: app)
        let libraryRow = app.buttons["Library Up Next Row"]
        assertHittable(libraryRow, named: "the Library's Up Next row")
        libraryRow.tap()
        XCTAssertTrue(waitForSelection("Up Next", in: app), "The Library's Up Next row selects the tab")
        XCTAssertFalse(app.buttons["Done"].exists, "No queue sheet")
    }

    @MainActor
    func testLibrarySettingsButtonOpensTheHub() throws {
        let app = makeApp(isSwitchOn: true)
        app.launch()

        openSection("Library", in: app)
        let button = librarySettingsButton(in: app)
        assertHittable(button, named: "Library Settings button")
        button.tap()
        assertScreen("Settings", named: "the Settings hub in the Library", in: app)
        assertExists(app.buttons["Settings Row Look & Feel"], named: "a hub row")
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected, "The hub opens inside the Library")
    }

    @MainActor
    func testFlippingOffBringsTheSettingsTabBack() throws {
        let app = makeApp(isSwitchOn: true)
        app.launch()

        openSection("Library", in: app)
        librarySettingsButton(in: app).tap()
        assertScreen("Settings", named: "the Settings hub in the Library", in: app)
        let row = app.buttons["Settings Row Look & Feel"]
        assertHittable(row, named: "Look & Feel row")
        row.tap()
        assertScreen("Look & Feel", named: "Look & Feel in the Library", in: app)

        tapToggle(upNextTabToggle(in: app), to: false)

        XCTAssertTrue(waitForNavigationItem("Settings", toExist: true, in: app), "Settings returns to the tab bar")
        XCTAssertTrue(waitForNavigationItem("Up Next", toExist: false, in: app), "Up Next leaves the tab bar")
        XCTAssertFalse(app.tabBars.buttons["More"].exists, "The bar never folds into More")
        assertScreen("Look & Feel", named: "Look & Feel, still in front", in: app)
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected, "The Library keeps the screen")

        tapBackButton(in: app)
        assertScreen("Settings", named: "the hub, still under Look & Feel", in: app)
        tapBackButton(in: app)
        assertScreen("Library", named: "the Library", in: app)
        assertDoesNotExist(librarySettingsButton(in: app), named: "Library Settings button after the switch is off")
    }

    /// After a launch with the switch stored on, the bar is the Up Next bar
    /// and stays that way. It starts watching only once Up Next is there, so
    /// it cannot see the first frame; that the first bar is already this one
    /// is `OpenCastAppRuntimeFirstSceneTests`.
    @MainActor
    func testAfterLaunchWithTheSwitchOnTheBarIsAndStaysTheUpNextBar() throws {
        let app = makeApp(isSwitchOn: true)
        app.launch()

        assertSectionItemExists("Up Next", named: "Up Next tab after launch", in: app, timeout: 10)
        let deadline = Date.now.addingTimeInterval(3)
        while Date.now < deadline {
            XCTAssertFalse(app.tabBars.buttons["Settings"].exists, "No Settings tab after launch")
            usleep(200_000)
        }
        XCTAssertEqual(
            app.tabBars.buttons.allElementsBoundByIndex.map(\.label),
            ["Library", "Up Next", "Inbox", "Downloads", "Search"]
        )
    }

    @MainActor
    func testKeyRequiredOpenSettingsLandsInTheLibrary() throws {
        let app = makeApp(isSwitchOn: true)
        app.launchArguments += [
            "--opencast-seed-analysis-trial=exhausted",
            "--opencast-present-analysis-key-required=ad_detection"
        ]
        app.launch()

        let openSettings = app.buttons["Analysis Key Required Open Settings"]
        assertHittable(openSettings, named: "key screen Open Settings", timeout: 10)
        openSettings.tap()

        assertScreen("AI Services", named: "AI Services from the key screen", in: app, timeout: 10)
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected, "AI Services opens inside the Library")
        XCTAssertFalse(app.tabBars.buttons["Settings"].exists, "No Settings tab with the switch on")
        tapBackButton(in: app)
        assertScreen("Settings", named: "the hub under AI Services", in: app)
        tapBackButton(in: app)
        assertScreen("Library", named: "the Library under the hub", in: app)
    }

    // MARK: Helpers

    @MainActor
    private func makeApp(isSwitchOn: Bool = false, seedsQueue: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--opencast-ui-testing", "--opencast-seed-ui-library", "--opencast-force-dark-mode"]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        if isSwitchOn {
            app.launchEnvironment["OPENCAST_SEED_UP_NEXT_TAB"] = "1"
        }
        if seedsQueue {
            app.launchEnvironment["OPENCAST_SEED_UP_NEXT_QUEUE"] = "1"
            app.launchEnvironment["OPENCAST_SEED_AUDIO_DURATION_SECONDS"] = "600"
        }
        return app
    }

    @MainActor
    private func upNextTabToggle(in app: XCUIApplication) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Up Next Tab")).firstMatch
    }

    @MainActor
    private func librarySettingsButton(in app: XCUIApplication) -> XCUIElement {
        toolbarButton("Settings", in: "Library", of: app)
    }

    /// The queued row on screen: the Inbox lists the same episodes under the
    /// same identifiers in its own tab.
    @MainActor
    private func visibleRow(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let query = app.buttons.matching(identifier: identifier)
        _ = query.firstMatch.waitForExistence(timeout: 5)
        return query.allElementsBoundByIndex.first(where: \.isHittable) ?? query.firstMatch
    }

    @MainActor
    private func nowPlayingCardIsPresented(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["Now Playing"].exists
    }

    @MainActor
    private func waitForSelection(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let button = app.tabBars.buttons[title]
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if button.exists, button.isSelected {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    @MainActor
    private func assertToggle(_ toggle: XCUIElement, isOn: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertExists(toggle, named: "Up Next Tab toggle", file: file, line: line)
        let expected = isOn ? ["1", "On", "true"] : ["0", "Off", "false"]
        let value = toggle.value as? String
        XCTAssertTrue(
            value.map { expected.contains($0) } ?? false,
            "The Up Next Tab toggle should be \(isOn ? "on" : "off"), read \(value ?? "nil")",
            file: file,
            line: line
        )
    }

    /// The switch sits at the row's trailing edge; a tap at the row's centre
    /// lands on the label. The row is rebuilt in the Library when it flips,
    /// and the query follows it there.
    @MainActor
    private func tapToggle(_ toggle: XCUIElement, to isOn: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertHittable(toggle, named: "Up Next Tab toggle", file: file, line: line)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let expected = isOn ? ["1", "On", "true"] : ["0", "Off", "false"]
        let changed = NSPredicate { object, _ in
            guard let element = object as? XCUIElement, let value = element.value as? String else {
                return false
            }
            return expected.contains(value)
        }
        let expectation = XCTNSPredicateExpectation(predicate: changed, object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }
}
