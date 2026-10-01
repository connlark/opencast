import Foundation

/// The Make a Playlist evaluation inputs a development Mac can point the
/// corpus suite at: a directory holding `corpus-manifest.json`, the expected
/// rankings and windows it names, and `<fixture>/fixture.json` files. The
/// fixtures are show metadata that never lives in the tree, so the suite is
/// enabled only when the variable names a directory with a manifest. Set it
/// as `TEST_RUNNER_<key>` on the xcodebuild environment.
nonisolated enum PlaylistEvaluationCorpus {
    static let inputsEnvironmentKey = "OPENCAST_PLAYLIST_EVALUATION_INPUTS"

    static var inputsDirectory: URL? {
        ProcessInfo.processInfo.environment[inputsEnvironmentKey]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static var manifestURL: URL? {
        inputsDirectory?.appending(path: "corpus-manifest.json")
    }

    static var isAvailable: Bool {
        manifestURL.map { FileManager.default.fileExists(atPath: $0.path()) } ?? false
    }

    static func fixtureURL(named fixture: String) -> URL? {
        inputsDirectory?.appending(path: "\(fixture)/fixture.json")
    }

    static func url(relativePath: String) -> URL? {
        inputsDirectory?.appending(path: relativePath)
    }
}
