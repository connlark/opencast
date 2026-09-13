import SwiftData
import SwiftUI

struct OpenCastRootPresentationModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @Binding var sheetDestination: SheetDestination?

    func body(content: Content) -> some View {
        @Bindable var appModel = appModel
        @Bindable var library = appModel.library

        content
            .sheet(item: $sheetDestination) { destination in
                SheetDestinationView(destination: destination, onDismiss: dismissSheet)
                    .environment(appModel)
                    .modelContext(modelContext)
            }
            .alert(
                "Playback Failed",
                item: $appModel.lastPlaybackError
            ) { _ in
            } message: { message in
                Text(message)
            }
            .alert(
                "Up Next Error",
                item: $appModel.lastUpNextError
            ) { _ in
            } message: { message in
                Text(message)
            }
            .alert(
                "Library Error",
                item: $library.lastErrorMessage
            ) { _ in
            } message: { message in
                Text(message)
            }
    }

    private func dismissSheet() {
        sheetDestination = nil
    }
}
