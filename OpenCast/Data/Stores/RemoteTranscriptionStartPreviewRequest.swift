import Foundation

nonisolated struct RemoteTranscriptionStartPreviewRequest: Identifiable, Sendable, Equatable {
    let episodeID: String
    let durationSeconds: Double?

    var id: String { episodeID }
}

nonisolated enum RemoteTranscriptionStartPreviewRouting {
    static func presentedRequest(
        _ request: RemoteTranscriptionStartPreviewRequest?,
        for episodeID: String
    ) -> RemoteTranscriptionStartPreviewRequest? {
        guard request?.episodeID == episodeID else {
            return nil
        }
        return request
    }
}
