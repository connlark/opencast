import Foundation

/// The Ask evaluation inputs a development Mac can point the corpus suites
/// at: a directory produced by the evaluation case generator, holding
/// `cases.json` and `fixtures/<name>.json`. The transcripts never live in
/// the tree, so the suites are enabled only when the variable names a
/// directory with a cases file. Set it as `TEST_RUNNER_<key>` on the
/// xcodebuild environment.
nonisolated enum TranscriptEvaluationCorpus {
    static let inputsEnvironmentKey = "OPENCAST_ASK_EVALUATION_INPUTS"

    static var inputsDirectory: URL? {
        ProcessInfo.processInfo.environment[inputsEnvironmentKey]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static var casesURL: URL? {
        inputsDirectory?.appending(path: "cases.json")
    }

    static var isAvailable: Bool {
        casesURL.map { FileManager.default.fileExists(atPath: $0.path()) } ?? false
    }

    static func fixtureURL(named fixture: String) -> URL? {
        inputsDirectory?.appending(path: "fixtures/\(fixture).json")
    }
}
