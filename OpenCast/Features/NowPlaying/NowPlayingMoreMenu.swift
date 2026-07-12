import SwiftUI

struct NowPlayingMoreMenu: View {
    let hasTranscript: Bool
    let canShowDescription: Bool
    let canShowShow: Bool
    let onTranscriptAction: () -> Void
    let onShowDescription: () -> Void
    let onShowShow: () -> Void

    var body: some View {
        Menu {
            Button(
                hasTranscript ? "Show Transcript" : "Generate Transcript",
                systemImage: "text.quote",
                action: onTranscriptAction
            )
            Button("Show Description", systemImage: "info.circle", action: onShowDescription)
                .disabled(!canShowDescription)
            Button("Show Show", systemImage: "rectangle.stack", action: onShowShow)
                .disabled(!canShowShow)
        } label: {
            Label("More Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // Non-interactive glass: the interactive variant pulses with light
        // under the Menu's highlight state on iOS 27.
        .glassEffect(.regular, in: .circle)
    }
}
