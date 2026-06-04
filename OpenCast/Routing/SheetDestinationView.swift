import SwiftUI

struct SheetDestinationView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let destination: SheetDestination
    let onDismiss: () -> Void

    var body: some View {
        switch destination {
        case .addPodcast:
            AddPodcastView(directoryService: appModel.podcastDirectoryService)
        case .importOPMLFile(let url):
            OPMLFileImportView(url: url)
        case .nukeConfirmation:
            NukeConfirmationSheet()
        case .onboarding:
            OnboardingView(
                directoryService: appModel.podcastDirectoryService,
                onCompleted: onDismiss
            )
        }
    }
}
