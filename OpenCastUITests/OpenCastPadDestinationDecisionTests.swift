import XCTest

/// Pins `OpenCastPadUITests.isPadDestination` — especially the hardware and
/// orchestrator-override disjuncts needed when the runner-idiom check alone
/// silently misses a physical iPad.
final class OpenCastPadDestinationDecisionTests: XCTestCase {
    func testPadDestinationDecisionTable() {
        let cases: [(environment: [String: String], deviceModel: String, isPadIdiom: Bool, expected: Bool, label: String)] = [
            ([:], "iPad", true, true, "pad idiom"),
            (["SIMULATOR_DEVICE_NAME": "iPad Pro 11-inch (M4)"], "iPhone", false, true, "named iPad simulator"),
            ([:], "iPad", false, true, "physical iPad hardware with misdetected runner idiom"),
            (["OPENCAST_FORCE_PAD": "1"], "iPhone", false, true, "direct orchestrator override"),
            (["TEST_RUNNER_OPENCAST_FORCE_PAD": "1"], "iPhone", false, true, "TEST_RUNNER orchestrator override"),
            (["OPENCAST_FORCE_PAD": "0"], "iPhone", false, false, "explicit non-1 override"),
            (["SIMULATOR_DEVICE_NAME": "iPhone 17", "SIMULATOR_UDID": "SOME-OTHER-UDID"], "iPhone", false, false, "iPhone simulator"),
            ([:], "iPhone", false, false, "no affirmative signal"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                OpenCastPadUITests.isPadDestination(
                    environment: testCase.environment,
                    deviceModel: testCase.deviceModel,
                    isPadIdiom: testCase.isPadIdiom
                ),
                testCase.expected,
                testCase.label
            )
        }
    }
}
