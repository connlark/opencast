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

    @MainActor
    func testSystemPlaylistQueryPlayAndAdd() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--opencast-ui-testing", "--opencast-seed-ui-library"]
        app.launchEnvironment["OPENCAST_SEED_PLAYLISTS"] = "1"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20))
        let definitions = IntentDefinitions(bundleIdentifier: "com.connor.opencast")
        let playlists = definitions.entities["OpenCastPlaylistEntity"]
        let suggested = try await playlists.suggestedEntities()
        XCTAssertEqual(suggested.count, 3)
        let commute = try XCTUnwrap(suggested.first { $0.identifier.instanceIdentifier == "ui-test-playlist-commute" })
        try await definitions.intents["PlayOpenCastPlaylistIntent"].makeIntent(playlist: commute).run()

        // The mini player's VoiceOver value is the assertable contract for the source line.
        let miniPlayer = app.buttons["Open Now Playing"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        for _ in 0..<60 {
            if (miniPlayer.value as? String)?.contains("playing from Seeded Commute") == true { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(
            (miniPlayer.value as? String)?.contains("playing from Seeded Commute") == true,
            "Mini player value reads \(String(describing: miniPlayer.value))"
        )

        let episodes = try await definitions.entities["OpenCastEpisodeEntity"].entities(identifiers: ["ui-test-episode-1"])
        let episode = try XCTUnwrap(episodes.first)
        let empty = playlists.makeReference(identifier: "ui-test-playlist-empty")
        // Twice: a retried Add must not duplicate the row.
        for _ in 0..<2 {
            try await definitions.intents["AddOpenCastEpisodeToPlaylistIntent"].makeIntent(episode: episode, playlist: empty).run()
        }

        // A foreground intent hands the scene back mid-transition, and a tab
        // tap that lands then is dropped; verify the switch and tap again.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        for _ in 0..<3 where !app.navigationBars["Library"].exists {
            openSection("Library", in: app)
            _ = app.navigationBars["Library"].waitForExistence(timeout: 3)
        }
        XCTAssertTrue(app.navigationBars["Library"].exists, "Library tab should be selected after the intents")
        let playlistsRow = app.buttons.matching(identifier: "Library Playlists Row").firstMatch
        XCTAssertTrue(playlistsRow.waitForExistence(timeout: 10))
        playlistsRow.tap()
        let emptyRow = app.descendants(matching: .any).matching(identifier: "playlist-row-ui-test-playlist-empty").firstMatch
        XCTAssertTrue(emptyRow.waitForExistence(timeout: 10))
        emptyRow.tap()
        let countLine = app.descendants(matching: .any).matching(identifier: "Playlist Count Line").firstMatch
        XCTAssertTrue(countLine.waitForExistence(timeout: 10))
        // A whole clause, so "1 episode" cannot pass for "11 episodes".
        var clauses: [String] = []
        for _ in 0..<40 {
            clauses = countLine.label.components(separatedBy: ", ")
            if clauses.contains("1 episode") { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(clauses.contains("1 episode"), "Playlist Count Line reads \(countLine.label)")
    }
}
