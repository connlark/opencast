/// What a remote transcription job was created for. A detect-ads pass keeps
/// its own stable `clientRequestID` per episode so it can never attach to a
/// plain Transcribe Remotely job (and vice versa).
nonisolated enum RemoteTranscriptionJobPurpose: String, Codable, Sendable {
    case transcription
    case adDetection
}
