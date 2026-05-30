import Foundation

nonisolated enum StreamingAudioValidationState: String, Codable, Sendable {
    case unknown
    case valid
    case missingValidator
    case validatorChanged
    case noRangeSupport
    case redirected
}
