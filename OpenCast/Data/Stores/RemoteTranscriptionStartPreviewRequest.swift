import Foundation

/// Pending "start remote transcription" intent: the pre-create consumption
/// preview sheet is presented for it before any job is created.
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
