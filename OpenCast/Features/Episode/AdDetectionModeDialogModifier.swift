import SwiftData
import SwiftUI

/// Shared first-tap "cloud or on this device?" dialog for Detect Ads entry
/// points. Present by setting the bound episode; a choice is remembered
/// device-locally and the selected pass starts immediately.
struct AdDetectionModeDialogModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @Binding var episode: EpisodeListItemSnapshot?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Detect ads in the cloud or on this device?",
            // Documented Binding(get:set:) exception: the dialog API has no
            // item: overload for non-Identifiable optionals.
            isPresented: Binding(
                get: { episode != nil },
                set: { isPresented in
                    if !isPresented {
                        episode = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Use Cloud Credits", action: chooseCloud)
            Button("Detect On This Device", action: chooseOnDevice)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Cloud detection transcribes this episode on OpenCast's server and uses your transcription credits — you get the transcript too. On-device detection is free: audio stays on this device, and the transcript text is sent to OpenCast's server to find the ads. Your choice is remembered; change it anytime in Settings."
            )
        }
    }

    private func chooseCloud() {
        choose(.cloud)
    }

    private func chooseOnDevice() {
        choose(.onDevice)
    }

    private func choose(_ mode: AdDetectionMode) {
        guard let episode else {
            return
        }
        appModel.chooseAdDetectionMode(mode, for: episode, modelContext: modelContext)
        self.episode = nil
    }
}

extension View {
    func adDetectionModeDialog(episode: Binding<EpisodeListItemSnapshot?>) -> some View {
        modifier(AdDetectionModeDialogModifier(episode: episode))
    }
}
