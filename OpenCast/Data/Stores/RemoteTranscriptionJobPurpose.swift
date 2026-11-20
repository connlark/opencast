/// Each purpose keeps its own stable `clientRequestID` per episode, so a job never attaches
/// across purposes.
nonisolated enum RemoteTranscriptionJobPurpose: String, Codable, Sendable {
    case transcription
    case adDetection
}
