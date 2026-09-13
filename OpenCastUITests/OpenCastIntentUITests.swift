import AppIntentsTesting
import XCTest

final class OpenCastIntentUITests: XCTestCase {
    @MainActor
    func testSystemEpisodeQueryQueueAndSearch() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--opencast-ui-testing", "--opencast-seed-ui-library", "--opencast-seed-episode-progress"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20))
        let definitions = IntentDefinitions(bundleIdentifier: "com.connor.opencast")
        let episodes = try await definitions.entities["OpenCastEpisodeEntity"].suggestedEntities()
        XCTAssertFalse(episodes.isEmpty)
        let episode = try XCTUnwrap(episodes.first)
        try await definitions.intents["AddOpenCastEpisodeToUpNextIntent"].makeIntent(episode: episode).run()
        try await definitions.intents["SearchOpenCastIntent"].makeIntent(query: "OpenCast").run()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "OpenCast")
        let missing = try await definitions.entities["OpenCastEpisodeEntity"].entities(identifiers: ["removed-episode"])
        XCTAssertTrue(missing.isEmpty)
    }
}
