import Foundation

public enum AppleSpeechTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case transcriberUnavailable
    case unsupportedLocale(String)
    case unsupportedAssets(localeIdentifier: String, status: String)
    case assetsNotInstalled(localeIdentifier: String, status: String)
    case assetInstallationUnavailable(localeIdentifier: String, status: String)
    case resumeNotSupported(TimeInterval)
    case noFinalTranscriptionResult

    public var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            "Apple Speech transcription is not available on this device."
        case let .unsupportedLocale(localeIdentifier):
            "Apple Speech transcription does not support locale \(localeIdentifier)."
        case let .unsupportedAssets(localeIdentifier, status):
            "Apple Speech assets for \(localeIdentifier) are not usable; status is \(status)."
        case let .assetsNotInstalled(localeIdentifier, status):
            "Apple Speech assets for \(localeIdentifier) are not installed; status is \(status)."
        case let .assetInstallationUnavailable(localeIdentifier, status):
            "Apple Speech did not provide an asset installation request for \(localeIdentifier); status is \(status)."
        case let .resumeNotSupported(resumeStart):
            "Apple Speech benchmark transcription cannot resume from \(resumeStart) seconds."
        case .noFinalTranscriptionResult:
            "Apple Speech did not produce a final transcription result."
        }
    }
}
