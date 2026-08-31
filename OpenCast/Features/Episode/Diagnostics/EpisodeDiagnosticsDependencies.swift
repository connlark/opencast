import Foundation
import SwiftData

/// Every side-effecting operation the diagnostics model performs, injected so
/// tests can prove nothing runs before the sheet opens and can drive each
/// flow deterministically. `live()` wires the real file system, network,
/// player, and download store.
struct EpisodeDiagnosticsDependencies {
    var fileInspector: any EpisodeDiagnosticsFileInspecting
    var networkProber: any EpisodeDiagnosticsNetworkProbing
    var playbackSnapshot: (OpenCastAppModel) -> EpisodeDiagnosticsPlaybackSnapshot
    var ensureCompletedDownload: (OpenCastAppModel, EpisodeListItemSnapshot, ModelContext) async throws -> EpisodeDownloadRecord
    var prepareShareFile: (URL, String, String) -> EpisodeDiagnosticsShareFile
    var cleanUpShareFile: (EpisodeDiagnosticsShareFile) -> Void

    static func live() -> EpisodeDiagnosticsDependencies {
        EpisodeDiagnosticsDependencies(
            fileInspector: EpisodeDiagnosticsFileInspector(),
            networkProber: EpisodeDiagnosticsNetworkProber(),
            playbackSnapshot: EpisodeDiagnosticsPlaybackSnapshot.capturing(from:),
            ensureCompletedDownload: { appModel, episode, modelContext in
                try await appModel.downloads.ensureCompletedDownload(
                    for: episode,
                    modelContext: modelContext
                ) {
                    try Task.checkCancellation()
                }
            },
            prepareShareFile: EpisodeDiagnosticsShareFilePreparer.prepare(source:podcastTitle:episodeTitle:),
            cleanUpShareFile: EpisodeDiagnosticsShareFilePreparer.cleanUp
        )
    }
}
