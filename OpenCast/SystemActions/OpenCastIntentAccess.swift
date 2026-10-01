import Foundation

enum OpenCastIntentAccess {
    static func catalog() async throws -> OpenCastEntityCatalog {
        OpenCastEntityCatalog(library: try await hydratedAppModel().library)
    }

    /// Playlist entities, most recently updated first; built here so the
    /// show and episode catalog never evaluates a smart playlist.
    static func playlists() async throws -> [OpenCastPlaylistEntity] {
        let appModel = try await hydratedAppModel()
        return OpenCastPlaylistEntity.entities(for: appModel.playlists.playlists) {
            appModel.playlistEpisodeCount(for: $0)
        }
    }

    static func perform(_ action: OpenCastSystemAction) async throws {
        let runtime = OpenCastAppRuntime.shared
        try await runtime.appModel.systemActions.perform(action, modelContext: runtime.modelContainer.mainContext)
    }

    /// The hydration, cancellation and library-unavailable checks every query
    /// shares.
    private static func hydratedAppModel() async throws -> OpenCastAppModel {
        try Task.checkCancellation()
        let runtime = OpenCastAppRuntime.shared
        await runtime.appModel.ensurePlaybackSurfaceHydrated(modelContext: runtime.modelContainer.mainContext)
        try Task.checkCancellation()
        if case .failed = runtime.appModel.library.state, runtime.appModel.library.subscriptions.isEmpty {
            throw OpenCastSystemActionError.libraryUnavailable
        }
        return runtime.appModel
    }
}
