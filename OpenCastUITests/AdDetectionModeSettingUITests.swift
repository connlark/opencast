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
        openSettingsScreen("Ad Skipping", in: app)
        sleep(1)

        // The Detect Ads picker is inline on the Ad Skipping screen: every
        // option is its own row, so tap the row and check its selection.
        let option = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", optionTitle)
        ).firstMatch
        var swipes = 0
        while !(option.exists && option.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(option.exists, "\(optionTitle) option should exist on the Ad Skipping screen")
        option.tap()
        sleep(1)

        XCTAssertTrue(option.isSelected, "\(optionTitle) should be selected after tapping it")
    }
}
