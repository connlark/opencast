import XCTest

/// Navigation helpers shared by the UI suites. Each asks today's question
/// first (the tab bar, the navigation bar) and answers from the section rail
/// only when the layout is one. The iPhone Duo's Closed pose keeps its
/// sections in a vertical rail: its `TabBar` element is an empty strip down
/// the trailing edge, the sections and the screen's toolbar buttons are
/// buttons beside it, and a pushed page has no `NavigationBar` element at all
/// (observed with XCUITest on the iPhone Duo simulator, iOS 27.2). A bottom
/// tab bar is wider than it is tall, so on the pinned iPhone, and in a
/// compact iPad window, every rail branch is unreachable and each helper
/// resolves exactly today's query. The Duo's open poses are not probed yet;
/// there the helpers keep today's behaviour.
extension XCTestCase {
    /// Opens a Settings hub row and waits for its sub-screen. A second tap on
    /// the Settings tab pops any pushed stack back to the hub first.
    @MainActor
    func openSettingsScreen(
        _ rowTitle: String,
        expecting screenTitle: String? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openSection("Settings", in: app, file: file, line: line)
        if !waitForSettingsHub(in: app, timeout: 2) {
            openSection("Settings", in: app, file: file, line: line)
        }

        // The hub keeps its scroll offset across pushes, so walk back to the
        // top before scrolling down for rows below the fold.
        let row = app.buttons["Settings Row \(rowTitle)"].firstMatch
        var swipes = 0
        while !(row.waitForExistence(timeout: 1) && row.isHittable), swipes < 3 {
            app.swipeDown()
            swipes += 1
        }
        swipes = 0
        while !(row.waitForExistence(timeout: 1) && row.isHittable), swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "Settings row \(rowTitle) should be hittable", file: file, line: line)
        bringClear(row, in: app)
        // Tap the centre bringClear cleared; `tap()` picks its own point.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let title = screenTitle ?? rowTitle
        XCTAssertTrue(
            waitForScreen(title, in: app, timeout: 10),
            "\(title) screen should push from the Settings hub",
            file: file,
            line: line
        )
    }

    @MainActor
    func openSection(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let tabButton = visibleTabButton(title, in: app) {
            tabButton.tap()
            return
        }

        XCTFail("\(title) navigation item should exist", file: file, line: line)
    }

    /// The section's hittable navigation item: the tab bar button, then the
    /// rail item, then any other button with the title outside a navigation
    /// bar, then the same after a swipe down. A bottom bar in the Duo's open
    /// poses is found by the first step if it answers to `app.tabBars`, which
    /// is today's behaviour until those poses are probed.
    @MainActor
    func visibleTabButton(
        _ title: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let tabButton = app.tabBars.buttons[title]
        if tabButton.waitForExistence(timeout: 1), tabButton.isHittable {
            return tabButton
        }

        if isSectionRail(in: app),
           let railItem = railButtons(named: title, region: .sections, in: app).last(where: \.isHittable) {
            return railItem
        }

        if let button = firstNonNavigationBarButton(title, in: app, timeout: 1) {
            return button
        }

        app.swipeDown()
        if tabButton.waitForExistence(timeout: 1), tabButton.isHittable {
            return tabButton
        }

        return firstNonNavigationBarButton(title, in: app, timeout: 1)
    }

    /// True when the sections live in a vertical rail (see `railColumn`).
    @MainActor
    func isSectionRail(in app: XCUIApplication) -> Bool {
        railColumn(in: app) != nil
    }

    /// The rail's horizontal span, or nil when the sections are not in one.
    /// A bottom tab bar holds its sections, which answers at once. Otherwise
    /// two signals observed in Closed: the tab bar element as a strip taller
    /// than it is wide that holds no buttons (69×678 at x 397 of a 466×678
    /// window, present while the tab accessory shows), or, without the strip,
    /// the sections themselves: the Library section as a button under a
    /// `Toolbar` element, taller than it is wide (44×58), in the window's
    /// leading or trailing quarter (the system picks the rail's edge by locale
    /// and device; Closed shows it trailing). An iPad's floating tab bar items
    /// are wider than tall and sit outside any `Toolbar`.
    @MainActor
    private func railColumn(in app: XCUIApplication) -> ClosedRange<CGFloat>? {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            if tabBar.buttons.firstMatch.exists {
                return nil
            }
            let strip = tabBar.frame
            if strip.height > strip.width {
                return strip.minX...strip.maxX
            }
        }
        let sections = app.toolbars.buttons.matching(NSPredicate(format: "label == %@", "Library"))
        for section in sections.allElementsBoundByIndex where section.exists {
            let window = contentExtent(in: app)
            let edgeBand = window.width * 0.25
            let frame = section.frame
            let atAnEdge = frame.midX < window.minX + edgeBand || frame.midX > window.maxX - edgeBand
            if frame.height > frame.width, atAnEdge {
                return frame.minX...frame.maxX
            }
        }
        return nil
    }

    /// A section's navigation item, for asserting on it: the tab bar button;
    /// in a rail, the rail button labelled with the section's title (observed
    /// in Closed: 44×58 at x 396), since a rail has no tab bar buttons.
    /// When neither is there it returns the tab bar button, so an assert on
    /// it fails as it always did.
    @MainActor
    func sectionItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let tabButton = app.tabBars.buttons[title]
        guard !tabButton.exists,
              isSectionRail(in: app),
              let railItem = railButtons(named: title, region: .sections, in: app).last
        else {
            return tabButton
        }
        return railItem
    }

    /// Waits for a section's navigation item (see `sectionItem`). Polls both
    /// placements, so it can stand right after launch, before the layout is
    /// known.
    @MainActor
    @discardableResult
    func waitForSectionItem(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let tabButton = app.tabBars.buttons[title]
        return pollNavigationState(timeout: timeout) {
            tabButton.exists
                || (isSectionRail(in: app) && !railButtons(named: title, region: .sections, in: app).isEmpty)
        }
    }

    @MainActor
    func assertSectionItemExists(
        _ title: String,
        named name: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitForSectionItem(title, in: app, timeout: timeout),
            "\(name) should exist",
            file: file,
            line: line
        )
    }

    /// Whether a section is offered at all, on screen or not: the tab bar
    /// button, the rail item, an iPad sidebar cell, or, given the tab's
    /// `symbol`, the iPad's floating tab bar button. iPadOS 27.2 draws that
    /// bar at regular width with no `TabBar` element: its items are buttons
    /// identified by the tab's symbol and labelled with its title, which no
    /// Library row is. `.exists`, never hittability, so an entry behind the
    /// iPad's closed sidebar still counts.
    @MainActor
    func navigationItemExists(_ title: String, symbol: String? = nil, in app: XCUIApplication) -> Bool {
        if sectionItem(title, in: app).exists
            || app.cells.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists {
            return true
        }
        guard let symbol else {
            return false
        }
        return app.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", symbol, title))
            .firstMatch
            .exists
    }

    /// Waits until `navigationItemExists(title, symbol:)` answers `exists`.
    @MainActor
    @discardableResult
    func waitForNavigationItem(
        _ title: String,
        symbol: String? = nil,
        toExist exists: Bool,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) -> Bool {
        pollNavigationState(timeout: timeout) {
            navigationItemExists(title, symbol: symbol, in: app) == exists
        }
    }

    /// Waits for the screen titled `title`: its navigation bar. In a rail a
    /// pushed page has no navigation bar at all (observed in Closed), so
    /// there, while no navigation bar is on screen, the page's title text
    /// stands in (`showsPageTitle`). `firstMatch` keeps a caller's
    /// `navigationBars[title].firstMatch`; without it the query is the plain
    /// `navigationBars[title]` the callers used.
    @MainActor
    @discardableResult
    func waitForScreen(
        _ title: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        firstMatch: Bool = false
    ) -> Bool {
        let titledBars = app.navigationBars[title]
        let navigationBar = firstMatch ? titledBars.firstMatch : titledBars
        if navigationBar.exists {
            return true
        }
        guard isSectionRail(in: app) else {
            // A zero timeout is a plain existence check, already answered.
            return timeout > 0 && navigationBar.waitForExistence(timeout: timeout)
        }
        let anyNavigationBar = app.navigationBars.firstMatch
        return pollNavigationState(timeout: timeout) {
            navigationBar.exists || (!anyNavigationBar.exists && showsPageTitle(title, in: app))
        }
    }

    /// Whether a page's title text reads `title`, by label. The tab
    /// accessory names the playing show, so on that show's pushed page its
    /// label is the same text: observed in Closed, `staticTexts["UI Test
    /// Show"].firstMatch` was the mini player's at (110, 632), the page's own
    /// title sitting at (135, 217) of the 678-point window. A text counts only
    /// outside every `mini-player…` element's frame and in the window's upper
    /// half, where a pushed page's title sits.
    @MainActor
    private func showsPageTitle(_ title: String, in app: XCUIApplication) -> Bool {
        let window = contentExtent(in: app)
        let accessories = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini-player"))
            .allElementsBoundByIndex
            .filter(\.exists)
            .map(\.frame)
        return app.staticTexts
            .matching(NSPredicate(format: "label == %@", title))
            .allElementsBoundByIndex
            .contains { text in
                guard text.exists else {
                    return false
                }
                let frame = text.frame
                return frame.midY < window.midY && !accessories.contains { $0.intersects(frame) }
            }
    }

    @MainActor
    func assertScreen(
        _ title: String,
        named name: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        firstMatch: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitForScreen(title, in: app, timeout: timeout, firstMatch: firstMatch),
            "\(name) should exist",
            file: file,
            line: line
        )
    }

    /// A screen's toolbar button: in the screen's navigation bar; in a rail
    /// the screen's toolbar buttons sit in the rail column's top slots
    /// (observed in Closed: the Library's Add at (399, 179)), so
    /// `navigationBars[title].buttons` finds nothing there.
    @MainActor
    func toolbarButton(_ name: String, in screenTitle: String, of app: XCUIApplication) -> XCUIElement {
        let navigationBarButton = app.navigationBars[screenTitle].buttons[name]
        guard !navigationBarButton.exists,
              isSectionRail(in: app),
              let railButton = railButtons(named: name, region: .toolbar, in: app).first
        else {
            return navigationBarButton
        }
        return railButton
    }

    /// `toolbarButton(_:in:of:)` for a button found by predicate, such as a
    /// toolbar menu that may carry its identifier or only its label.
    @MainActor
    func toolbarButton(
        matching predicate: NSPredicate,
        in screenTitle: String,
        of app: XCUIApplication
    ) -> XCUIElement {
        let navigationBarButton = app.navigationBars[screenTitle].buttons.matching(predicate).firstMatch
        guard !navigationBarButton.exists,
              isSectionRail(in: app),
              let railButton = railButtons(matching: predicate, region: .toolbar, in: app).first
        else {
            return navigationBarButton
        }
        return railButton
    }

    /// Taps Back: the first navigation-bar button; in a rail a pushed page
    /// has no navigation bar and Back is the rail's `BackButton`, which has
    /// no label (observed in Closed: 38×38 at (399, 179)). `firstBarOnly`
    /// keeps the App Store suite's former scope, the first navigation bar's
    /// first button, rather than the first button of any bar.
    @MainActor
    func tapBackButton(
        in app: XCUIApplication,
        firstBarOnly: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var backButton = firstBarOnly
            ? app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            : app.navigationBars.buttons.firstMatch
        if !backButton.exists, isSectionRail(in: app) {
            backButton = app.buttons["BackButton"].firstMatch
        }
        assertExists(backButton, named: "navigation back button", file: file, line: line)
        backButton.tap()
    }

    /// Whether `element` has settled clear of the section bar: above a bottom
    /// tab bar, where an element resting on the bar's top edge is clear of it
    /// (half a point of tolerance for that resting line); beside a rail, which
    /// runs the window's full height (observed in Closed: trailing, from
    /// x 396), on the horizontal axis instead, on whichever side of the
    /// window the rail sits.
    @MainActor
    func isClearOfSectionBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if let rail = railColumn(in: app) {
            if rail.upperBound < contentExtent(in: app).midX {
                return element.frame.minX >= rail.upperBound
            }
            return element.frame.maxX <= rail.lowerBound
        }
        return element.frame.maxY <= app.tabBars.firstMatch.frame.minY + 0.5
    }

    /// The app's content extent in element space: the window-wide `Toolbar`
    /// element's frame. A landscape pose reports the app's (and so the
    /// window's) frame portrait-shaped while its elements are landscape, so a
    /// rule that compares element frames reads its extent from an element.
    /// Used only on a rail, which always sits under that `Toolbar`.
    @MainActor
    private func contentExtent(in app: XCUIApplication) -> CGRect {
        app.toolbars.firstMatch.frame
    }

    /// Scrolls `element` until the point a tap on it lands (`tapPoint`, in its
    /// own normalized frame) lies outside everything that covers the content
    /// while XCUITest still calls what is under it hittable
    /// (`coveringFrames`). For a caller that taps exactly that point.
    @MainActor
    func bringClear(
        _ element: XCUIElement,
        tapPoint: CGVector = CGVector(dx: 0.5, dy: 0.5),
        in app: XCUIApplication
    ) {
        liftClear(element, in: app) { frame in
            CGRect(
                x: frame.minX + frame.width * tapPoint.dx,
                y: frame.minY + frame.height * tapPoint.dy,
                width: 0.01,
                height: 0.01
            )
        }
    }

    /// `bringClear` for an element its caller taps where it chooses (`tap()`'s
    /// own point, or a coordinate such as a toggle's trailing end): lifts
    /// until no part of its frame lies under a cover. On the pinned iPhone
    /// this can lift a hittable row whose frame reaches within 12 points of
    /// the tab accessory.
    @MainActor
    func bringFrameClear(_ element: XCUIElement, in app: XCUIApplication) {
        liftClear(element, in: app) { $0 }
    }

    /// While the probed part of `element` (`probe`, from its frame) meets a
    /// cover, a slow drag held at its end, started on the content just above
    /// the highest such cover, lifts the content by the overlap plus the
    /// content's 10-point touch slop (a 31-point drag moved a row 21) and no
    /// further; three attempts bound it.
    @MainActor
    private func liftClear(
        _ element: XCUIElement,
        in app: XCUIApplication,
        probe: (CGRect) -> CGRect
    ) {
        for _ in 0..<3 {
            let frame = element.frame
            let probed = probe(frame)
            let covers = coveringFrames(in: app).filter { $0.intersects(probed) }
            guard let coverTop = covers.map(\.minY).min() else {
                return
            }
            let lift = probed.maxY - coverTop + 2
            let start = element.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 8, dy: coverTop - 24 - frame.minY))
            start.press(
                forDuration: 0.1,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: -(lift + 10))),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )
        }
    }

    /// What covers the app's content in a window of its own, so XCUITest
    /// still reports the content under it hittable and a tap there lands on
    /// the cover instead:
    /// - a shown software keyboard. Its panel starts 41 points above its
    ///   `Keyboard` element on the iPhone 18 Pro (iOS 27.2: the panel's top
    ///   edge at y 549 in a screen recording, the element's at 590), so the
    ///   frame starts 44 points above the element, plus a 16-point margin.
    /// - the tab accessory, every `mini-player…` element, 12 points larger all
    ///   round: observed in Closed, its capsule floats over the content
    ///   column's bottom (a Settings row centred at (201, 640) under the
    ///   (62, 608) 266×44 element opened Now Playing), and the visible glass
    ///   exceeds that element by 12 points across and 6 down (the app's own
    ///   accessory frame is (50, 602) 290×56). On the pinned iPhone the
    ///   accessory shares the content's window, so a row XCUITest calls
    ///   hittable never has its tap point under it; a point or frame within
    ///   12 points of it is lifted clear.
    @MainActor
    func coveringFrames(in app: XCUIApplication) -> [CGRect] {
        var frames: [CGRect] = []
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let element = keyboard.frame
            frames.append(CGRect(
                x: element.minX,
                y: element.minY - 44 - 16,
                width: element.width,
                height: element.height + 44 + 16
            ))
        }
        frames += app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini-player"))
            .allElementsBoundByIndex
            .filter(\.exists)
            .map { $0.frame.insetBy(dx: -12, dy: -12) }
        return frames
    }

    /// Drags the Now Playing card down from a point on the card itself, its
    /// own (0.5, 0.24), by `fraction` of the card's own height, measured in the
    /// card's coordinate space (a landscape pose reports the app's frame
    /// portrait-shaped while its elements are landscape). The compact card is
    /// the full window, so its height is the window's and 0.24 of it is the
    /// window point the drags always started from; 0.06, where the iPad suite's bottom-anchored card
    /// starts, lands in a tall phone's status bar band (y ≈ 52 on the iPhone
    /// 18 Pro), which does not hand the drag to the card.
    /// The dismissal is distance-based (`NowPlayingOverlayView`: 0.28 of the
    /// dismiss distance, or a predicted 0.56), so each caller keeps its former
    /// drag's travel, velocity and hold rather than its end point.
    @MainActor
    func dragNowPlayingCard(
        _ card: XCUIElement,
        travelling fraction: CGFloat,
        velocity: XCUIGestureVelocity? = nil,
        holdDuration: TimeInterval = 0
    ) {
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
        let end = start.withOffset(CGVector(dx: 0, dy: fraction * card.frame.height))
        if let velocity {
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: holdDuration)
        } else {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    /// The Settings hub is on screen: its titled navigation bar, or its first
    /// row, which no pushed Settings screen carries.
    @MainActor
    private func waitForSettingsHub(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let navigationBar = app.navigationBars["Settings"]
        let firstRow = app.buttons["Settings Row Playback"]
        return pollNavigationState(timeout: timeout) {
            navigationBar.exists || firstRow.exists
        }
    }

    /// The rail column's two groups: the screen's toolbar buttons hold its top
    /// slots and the sections its bottom group, which starts at the Library
    /// section (observed in Closed: toolbar buttons at y 179 and 239, the
    /// sections from y 394 to 652). A label both carry, such as the Downloads
    /// toolbar's Search and the Search section, answers only in its own group,
    /// so one never stands in for the other.
    private enum RailRegion {
        case toolbar
        case sections
    }

    /// Buttons labelled `name` in one group of the rail column (`railColumn`),
    /// top to bottom; by label only, since a rail item's identifier changes
    /// between launches (observed in Closed: the tab's symbol name, or none).
    @MainActor
    private func railButtons(named name: String, region: RailRegion, in app: XCUIApplication) -> [XCUIElement] {
        railButtons(matching: NSPredicate(format: "label == %@", name), region: region, in: app)
    }

    @MainActor
    private func railButtons(
        matching predicate: NSPredicate,
        region: RailRegion,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        guard let column = railColumn(in: app) else {
            return []
        }
        let inColumn = { (button: XCUIElement) in button.exists && column.contains(button.frame.midX) }
        let sectionsTop = app.buttons
            .matching(NSPredicate(format: "label == %@", "Library"))
            .allElementsBoundByIndex
            .filter(inColumn)
            .map(\.frame.minY)
            .min()
        return app.buttons
            .matching(predicate)
            .allElementsBoundByIndex
            .filter { button in
                guard inColumn(button) else {
                    return false
                }
                // No Library rail button, no trustworthy boundary between
                // the groups: answer nothing rather than either group.
                guard let sectionsTop else {
                    return false
                }
                return region == .sections
                    ? button.frame.minY >= sectionsTop
                    : button.frame.minY < sectionsTop
            }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    @MainActor
    private func pollNavigationState(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else {
                return false
            }
            usleep(250_000)
        }
        return true
    }

    @MainActor
    private func firstNonNavigationBarButton(
        _ title: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let predicate = NSPredicate(format: "label == %@", title)
        let buttons = app.buttons.matching(predicate)
        guard buttons.firstMatch.waitForExistence(timeout: timeout) else {
            return nil
        }

        let navigationBarFrames = navigationBarButtonFrames(title, in: app)
        for index in 0..<buttons.count {
            let button = buttons.element(boundBy: index)
            guard button.exists, button.isHittable else {
                continue
            }
            if !navigationBarFrames.contains(where: { $0.equalTo(button.frame) }) {
                return button
            }
        }

        return nil
    }

    @MainActor
    private func navigationBarButtonFrames(
        _ title: String,
        in app: XCUIApplication
    ) -> [CGRect] {
        let predicate = NSPredicate(format: "label == %@", title)
        let buttons = app.navigationBars.buttons.matching(predicate)
        guard buttons.firstMatch.exists else {
            return []
        }

        return (0..<buttons.count)
            .map { buttons.element(boundBy: $0) }
            .filter(\.exists)
            .map(\.frame)
    }
}
