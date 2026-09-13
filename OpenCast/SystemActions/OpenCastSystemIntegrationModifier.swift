import SwiftData
import SwiftUI

struct OpenCastSystemIntegrationModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .task(id: appModel.library.episodeSearchCorpusRevision) { await updateIndex() }
            .task(id: appModel.library.activePodcastIDs) { await updateIndex() }
    }

    private func updateIndex() async {
        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        guard !Task.isCancelled, !OpenCastLaunchConfiguration.current.usesInMemoryStore else { return }
        if case .failed = appModel.library.state { return }
        await OpenCastEntityIndex.shared.update(OpenCastEntityCatalog(library: appModel.library))
    }
}
