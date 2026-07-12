import XCTest

extension XCTestCase {
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

    @MainActor
    func visibleTabButton(
        _ title: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let tabButton = app.tabBars.buttons[title]
        if tabButton.waitForExistence(timeout: 1), tabButton.isHittable {
            return tabButton
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
