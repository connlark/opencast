import XCTest

/// Harness utility, not a regression test: flips the device-local Detect Ads
/// mode preference through the real Settings UI. On-device measurement runs
/// (see `ScrollJankDeviceProbeUITests`) need `onDevice` so a Detect Ads tap
/// exercises Apple Speech instead of auto-routing to the cloud lane, and the
/// preference must be restored afterwards.
///
/// Opt-in via `TEST_RUNNER_OPENCAST_ADMODE_SET={onDevice|cloud|ask}`; skips
/// everywhere else so regression lanes are unaffected.
final class AdDetectionModeSettingUITests: XCTestCase {
    private static let modeEnvironmentKey = "OPENCAST_ADMODE_SET"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.modeEnvironmentKey]?.isEmpty == false,
            "ad-detection mode setter is opt-in; set TEST_RUNNER_OPENCAST_ADMODE_SET"
        )
        continueAfterFailure = false
    }

    @MainActor
    func testSetAdDetectionMode() throws {
        let optionTitle: String
        switch ProcessInfo.processInfo.environment[Self.modeEnvironmentKey] {
        case "onDevice": optionTitle = "On This Device"
        case "cloud": optionTitle = "In the Cloud"
        case "ask": optionTitle = "Ask First Time"
        case let other: throw XCTSkip("unknown ad-detection mode: \(other ?? "nil")")
        }

        let app = XCUIApplication()
        app.launch()
        openSection("Settings", in: app)
        sleep(1)

        let pickerPredicate = NSPredicate(format: "label BEGINSWITH %@", "Detect Ads")
        var picker = app.buttons.matching(pickerPredicate).firstMatch
        if !picker.waitForExistence(timeout: 2) {
            picker = app.descendants(matching: .any).matching(pickerPredicate).firstMatch
        }
        var swipes = 0
        while !(picker.exists && picker.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(picker.exists, "Detect Ads picker should exist in Settings")
        picker.tap()

        let option = app.buttons[optionTitle].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), "\(optionTitle) option should appear")
        option.tap()
        sleep(1)

        let updated = app.buttons.matching(pickerPredicate).firstMatch
        XCTAssertTrue(
            updated.waitForExistence(timeout: 3) && updated.label.contains(optionTitle),
            "picker should reflect \(optionTitle), got: \(updated.exists ? updated.label : "missing")"
        )
    }
}
