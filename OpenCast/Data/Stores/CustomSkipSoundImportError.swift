import Foundation

/// No case leaves a file behind.
nonisolated enum CustomSkipSoundImportError: Error, Equatable, Sendable {
    case tooLarge
    case tooLong
    case unplayable
    case fileOperationFailed(String)
    case cancelled

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
