import XCTest

struct SpringBoardNotificationTimeout: Error, CustomStringConvertible {
    var label: String

    var description: String {
        "Notification containing \"\(label)\" did not appear on SpringBoard before the timeout."
    }
}

extension XCTestCase {
    @MainActor
    func waitForSpringBoardNotification(
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

        throw SpringBoardNotificationTimeout(label: label)
    }

    @MainActor
    func openNotificationCenter(in springboard: XCUIApplication) {
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    func settleSpringBoardNotificationSurface(in springboard: XCUIApplication) {
        for _ in 0..<3 {
            openNotificationCenter(in: springboard)
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
