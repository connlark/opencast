import Foundation

/// Why an imported skip sound was not kept. None of them leaves a file.
nonisolated enum CustomSkipSoundImportError: Error, Equatable, Sendable {
    /// Larger than any 3-second sound can be (`CustomSkipSoundFiles.maximumFileSize`).
    case tooLarge
    case tooLong
    case unplayable
    /// Reading the chosen file or writing the copy failed.
    case fileOperationFailed(String)
    /// The import's task was cancelled while the file was checked.
    case cancelled

    /// The sentence the picker shows; nil when it shows none.
    var message: String? {
        switch self {
        case .tooLarge, .tooLong:
            "Sounds can be up to 3 seconds long."
        case .unplayable:
            "That file can't be played."
        case .fileOperationFailed(let description):
            "Unable to add the sound: \(description)"
        case .cancelled:
            nil
        }
    }
}
