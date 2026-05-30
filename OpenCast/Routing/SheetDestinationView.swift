import SwiftUI

struct SheetDestinationView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let destination: SheetDestination

    var body: some View {
        switch destination {
        case .addPodcast:
            AddPodcastView(directoryService: appModel.podcastDirectoryService)
        case .importOPMLFile(let url):
            OPMLFileImportView(url: url)
        case .onboarding:
            OnboardingView(discoveryService: appModel.podcastDiscoveryService)
        }
    }
}
