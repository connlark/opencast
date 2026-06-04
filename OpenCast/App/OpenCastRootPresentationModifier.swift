import SwiftUI

struct OpenCastRootPresentationModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var sheetDestination: SheetDestination?

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheetDestination) { destination in
                SheetDestinationView(destination: destination, onDismiss: dismissSheet)
            }
            // The alert API needs Bool bindings because the presented Strings are not Identifiable.
            .alert(
                "Playback Failed",
                isPresented: playbackErrorAlertBinding,
                presenting: appModel.lastPlaybackError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .alert(
                "Library Error",
                isPresented: libraryErrorAlertBinding,
                presenting: appModel.library.lastErrorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    private var playbackErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appModel.lastPlaybackError != nil },
            set: { if !$0 { appModel.lastPlaybackError = nil } }
        )
    }

    private func dismissSheet() {
        sheetDestination = nil
    }

    private var libraryErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appModel.library.lastErrorMessage != nil },
            set: { if !$0 { appModel.library.clearLastError() } }
        )
    }
}
