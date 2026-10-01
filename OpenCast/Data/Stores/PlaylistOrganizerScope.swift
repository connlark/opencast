/// What part of the show the model saw.
nonisolated struct PlaylistOrganizerScope: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case all
        case bestMatches
        case newest
    }

    var kind: Kind
    var sentCount: Int
    var totalCount: Int

    /// The scope as the prompt states it. Plain digits, never locale-formatted,
    /// so the model reads the same text on every device.
    var promptText: String {
        let sent = String(sentCount)
        let total = String(totalCount)
        return switch kind {
        case .all:
            "all \(total)"
        case .bestMatches:
            "the \(sent) of \(total) that best match the request"
        case .newest:
            "the newest \(sent) of \(total)"
        }
    }
}
