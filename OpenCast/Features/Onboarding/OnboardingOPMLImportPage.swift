import Foundation
import SwiftData
import SwiftUI

struct OnboardingOPMLImportPage: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var importFlow = OPMLImportFlow()

    var body: some View {
        Form {
            Section {
                Text("Already have subscriptions in another podcast app?")
                    .font(.headline)

                Text("Import an OPML file to subscribe to those RSS feeds here. You can also skip this and add shows later.")
                    .foregroundStyle(.secondary)

                OnboardingApplePodcastsShortcutDisclosure()

                OPMLImportStateView(
                    state: importFlow.state,
                    importButtonTitle: "Import OPML",
                    importAction: importFlow.showImporter
                )
            } header: {
                Text("Import Subscriptions")
            } footer: {
                Text(OPMLImportCopy.subscriptionsOnlyFooter)
            }
        }
        .fileImporter(
            isPresented: $importFlow.isShowingImporter,
            allowedContentTypes: OPMLFileDocument.readableContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .onDisappear {
            importFlow.cancelImportTask()
        }
    }

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        importFlow.handleImportResult(
            result,
            libraryStore: appModel.library,
            modelContext: modelContext
        )
    }
}
