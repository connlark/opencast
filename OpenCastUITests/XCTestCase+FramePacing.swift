import XCTest

extension XCTestCase {
    /// Reads the frame-pacing probe summaries the app publishes through the
    /// accessibility tree and saves them as an .xcresult attachment, since the
    /// probe's on-disk logs live on an unreadable simulator clone and the
    /// runner's stdout is not streamed to the host.
    @MainActor
    @discardableResult
    func captureFramePacingSummary(
        in app: XCUIApplication,
        expectedSessions: Int,
        containing requiredEvent: String? = nil,
        timeout: TimeInterval = 15
    ) -> String {
        let element = app.descendants(matching: .any)["Frame Pacing Summary"]
        let deadline = Date().addingTimeInterval(timeout)
        var value = ""
        while Date() < deadline {
            value = (element.value as? String) ?? ""
            let sessions = value.components(separatedBy: "session=").count - 1
            let hasRequiredEvent = requiredEvent.map(value.contains) ?? true
            if sessions >= expectedSessions, hasRequiredEvent {
                break
            }
            usleep(250_000)
        }

        let attachment = XCTAttachment(string: value)
        attachment.name = "FramePacingSummary"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("FRAMEPACING_SUMMARY: \(value)")
        return value
    }

    @MainActor
    func frameSummaryValue(in app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["Frame Pacing Summary"]
        guard element.waitForExistence(timeout: 10) else {
            return "frame probe element missing"
        }
        return (element.value as? String) ?? ""
    }
}
