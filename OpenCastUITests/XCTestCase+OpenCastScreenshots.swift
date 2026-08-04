import XCTest

extension XCTestCase {
    @MainActor
    func attachSmokeScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Timestamp-suffixed variant for repeated poll captures that need
    /// unique attachment names.
    @MainActor
    func attachTimestampedSmokeScreenshot(named name: String) {
        attachSmokeScreenshot(named: "\(name)_\(ISO8601DateFormatter().string(from: .now))")
    }

    /// App-scoped capture (`app.screenshot()`), semantically distinct from
    /// the full-screen `XCUIScreen` capture — device-run evidence wants the
    /// app frame, not the whole screen.
    @MainActor
    func attachAppScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func assertExists(
        _ element: XCUIElement,
        named name: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "\(name) should exist",
            file: file,
            line: line
        )
    }

    @MainActor
    func assertHittable(
        _ element: XCUIElement,
        named name: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertExists(element, named: name, timeout: timeout, file: file, line: line)
        let predicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "\(name) should be hittable",
            file: file,
            line: line
        )
    }

    @MainActor
    func assertDoesNotExist(
        _ element: XCUIElement,
        named name: String,
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForNonExistence(timeout: timeout),
            "\(name) should not exist",
            file: file,
            line: line
        )
    }

    @MainActor
    func assertMiniPlayerDoesNotCover(
        _ element: XCUIElement,
        named name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let miniPlayer = app.buttons["Open Now Playing"]
        assertExists(miniPlayer, named: "mini-player", file: file, line: line)
        assertExists(element, named: name, file: file, line: line)

        XCTAssertTrue(
            element.isHittable,
            "\(name) should be hittable",
            file: file,
            line: line
        )
        XCTAssertFalse(
            element.frame.intersects(miniPlayer.frame),
            "\(name) should not intersect the mini-player frame",
            file: file,
            line: line
        )
    }
}
