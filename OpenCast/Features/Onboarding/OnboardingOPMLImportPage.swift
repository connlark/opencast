import Foundation
import SwiftData
import SwiftUI

struct OnboardingOPMLImportPage: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var importFlow = OPMLImportFlow()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Import Subscriptions")
                        .font(.largeTitle)
                        .bold()

                    Text("Already have shows in another podcast app? Bring over an OPML file now, or skip and add podcasts later.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                OnboardingOPMLImportActionCard(
                    state: importFlow.state,
                    importAction: importFlow.showImporter
                )

                VStack(alignment: .leading, spacing: 12) {
                    OnboardingApplePodcastsShortcutDisclosure()

                    OnboardingPitchRow(
                        systemImage: "list.bullet.clipboard",
                        title: "Subscriptions only",
                        message: "Progress, downloads, queues, refresh logs, and caches stay on this device."
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.visible)
        .fileImporter(
            isPresented: $importFlow.isShowingImporter,
            allowedContentTypes: OPMLFileDocument.readableContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        // No onDisappear cancel: advancing past this page must not abort a
        // running import mid-batch (the flow still cancels in deinit).
    }

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        importFlow.handleImportResult(
            result,
            libraryStore: appModel.library,
            modelContext: modelContext
        )
    }
}
