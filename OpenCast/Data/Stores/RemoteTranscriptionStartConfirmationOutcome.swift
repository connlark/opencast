nonisolated enum RemoteTranscriptionStartConfirmationOutcome: Equatable, Sendable {
    case started(episodeID: String)
    case unavailable(message: String)
}
