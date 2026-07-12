import Foundation

public enum OpenCastTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case missingResource(String)
    case audioFileNotFound(URL)
    case invalidClipStart(TimeInterval)
    case invalidClipDuration(TimeInterval)
    case invalidResumeStart(TimeInterval)
    case invalidAudioDuration(TimeInterval)
    case emptyAudioClip(clipStart: TimeInterval, clipDuration: TimeInterval)
    case noTranscriptionResult
    case unsupportedModelIdentifier(String)
    case modelNotInstalled(modelIdentifier: String, version: String)
    case remoteManifestUnavailable(URL)
    case remoteManifestSignatureUnavailable(URL)
    case remoteManifestMissingModel(modelIdentifier: String, version: String)
    case invalidRemoteManifest(String)
    case invalidRemoteManifestSignature(String)
    case remoteModelDownloadFailed(URL)
    case checksumMismatch(path: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .missingResource(resource):
            "Missing bundled transcription resource: \(resource)"
        case let .audioFileNotFound(url):
            "Audio file does not exist: \(url.path)"
        case let .invalidClipStart(start):
            "Clip start must be zero or greater; got \(start)."
        case let .invalidClipDuration(duration):
            "Clip duration must be greater than 0 and no more than \(OpenCastTranscriptionRequest.maximumClipDuration) seconds; got \(duration)."
        case let .invalidResumeStart(start):
            "Resume start must be zero or greater and inside the audio duration; got \(start)."
        case let .invalidAudioDuration(duration):
            "Audio duration must be greater than 0; got \(duration)."
        case let .emptyAudioClip(clipStart, clipDuration):
            "The requested clip contains no audio samples from \(clipStart) seconds for \(clipDuration) seconds."
        case .noTranscriptionResult:
            "WhisperKit did not produce a transcription result."
        case let .unsupportedModelIdentifier(modelIdentifier):
            "Unsupported transcription model: \(modelIdentifier)."
        case let .modelNotInstalled(modelIdentifier, version):
            "Transcription model is not installed: \(modelIdentifier) \(version)."
        case let .remoteManifestUnavailable(url):
            "Remote transcription model manifest is unavailable: \(url.absoluteString)."
        case let .remoteManifestSignatureUnavailable(url):
            "Remote transcription model manifest signature is unavailable: \(url.absoluteString)."
        case let .remoteManifestMissingModel(modelIdentifier, version):
            "Remote transcription model manifest does not include \(modelIdentifier) \(version)."
        case let .invalidRemoteManifest(reason):
            "Remote transcription model manifest is invalid: \(reason)."
        case let .invalidRemoteManifestSignature(reason):
            "Remote transcription model manifest signature is invalid: \(reason)."
        case let .remoteModelDownloadFailed(url):
            "Failed to download remote transcription model file: \(url.absoluteString)."
        case let .checksumMismatch(path, expected, actual):
            "Transcription model checksum mismatch for \(path): expected \(expected), got \(actual)."
        }
    }
}
