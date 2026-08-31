import SwiftData
import SwiftUI

/// Copyable snapshot of everything relevant to an ad-skip investigation for
/// one episode. All loading starts here — never from the episode screen or
/// its menu — and cancels on dismissal.
struct EpisodeDiagnosticsSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let episodeID: String

    @State private var model: EpisodeDiagnosticsModel

    init(episodeID: String) {
        self.episodeID = episodeID
        _model = State(initialValue: EpisodeDiagnosticsModel(episodeID: episodeID))
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                Section("Actions") {
                    Button("Refresh Diagnostics", systemImage: "arrow.clockwise", action: model.requestRefresh)
                    Button("Copy Report", systemImage: "doc.on.doc", action: model.copyReport)
                    ShareLink("Share Report", item: model.reportText())
                    EpisodeDiagnosticsMP3ShareSection(model: model)
                }

                ForEach(EpisodeDiagnosticsSectionID.allCases) { id in
                    EpisodeDiagnosticsSectionView(id: id, state: model.state(for: id))
                }
            }
            .navigationTitle("Episode Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
            .task(id: model.loadGeneration) {
                await model.load(appModel: appModel)
            }
            .onDisappear(perform: model.handleDisappear)
            .sheet(item: $model.presentedShareFile, onDismiss: model.shareSheetDismissed) { shareFile in
                EpisodeDiagnosticsActivitySheet(fileURL: shareFile.url)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

#Preview("Dark") {
    EpisodeDiagnosticsSheet(episodeID: "preview-episode")
        .environment(OpenCastAppModel())
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    EpisodeDiagnosticsSheet(episodeID: "preview-episode")
        .environment(OpenCastAppModel())
        .preferredColorScheme(.light)
}
