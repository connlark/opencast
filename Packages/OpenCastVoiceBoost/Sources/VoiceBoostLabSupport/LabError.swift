import Foundation

enum LabError: LocalizedError {
    case invalidArguments(String)
    case invalidWAV(String)
    case unknownPreset(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            message
        case .invalidWAV(let message):
            message
        case .unknownPreset(let preset):
            "Unknown preset: \(preset)"
        }
    }
}
