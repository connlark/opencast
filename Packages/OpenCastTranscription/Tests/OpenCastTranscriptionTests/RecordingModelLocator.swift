import Foundation
@testable import OpenCastTranscription

final class RecordingModelLocator: OpenCastWhisperModelLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _modelIdentifier: String

    init(modelIdentifier: String = "model-a") {
        _modelIdentifier = modelIdentifier
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func updateModelIdentifier(_ modelIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        _modelIdentifier = modelIdentifier
    }

    func modelLocation() throws -> OpenCastWhisperModelLocation {
        lock.lock()
        _callCount += 1
        let modelIdentifier = _modelIdentifier
        lock.unlock()

        let baseURL = FileManager.default.temporaryDirectory.appending(path: "OpenCastTranscriptionTests")
        return OpenCastWhisperModelLocation(
            modelIdentifier: modelIdentifier,
            modelFolder: baseURL.appending(path: modelIdentifier),
            tokenizerFolder: baseURL.appending(path: "\(modelIdentifier)-tokenizer")
        )
    }
}
