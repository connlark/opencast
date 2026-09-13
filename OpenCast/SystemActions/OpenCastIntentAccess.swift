import Foundation

enum OpenCastIntentAccess {
    static func catalog() async throws -> OpenCastEntityCatalog {
        try Task.checkCancellation()
        let runtime = OpenCastAppRuntime.shared
        await runtime.appModel.ensurePlaybackSurfaceHydrated(modelContext: runtime.modelContainer.mainContext)
        try Task.checkCancellation()
        if case .failed = runtime.appModel.library.state, runtime.appModel.library.subscriptions.isEmpty {
            throw OpenCastSystemActionError.libraryUnavailable
        }
        return OpenCastEntityCatalog(library: runtime.appModel.library)
    }

    static func perform(_ action: OpenCastSystemAction) async throws {
        let runtime = OpenCastAppRuntime.shared
        try await runtime.appModel.systemActions.perform(action, modelContext: runtime.modelContainer.mainContext)
    }
}
