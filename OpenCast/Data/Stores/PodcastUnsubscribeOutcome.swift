nonisolated enum PodcastUnsubscribeOutcome: Equatable, Sendable {
    case removed(warning: String?)
    case failed(message: String)

    var userFacingMessage: String? {
        switch self {
        case .removed(let warning):
            warning
        case .failed(let message):
            message
        }
    }
}
