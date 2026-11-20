import SwiftUI

/// Reads no environment, so it behaves alike in a row's context menu and in a toolbar menu.
struct EpisodeUpNextMenuButtons: View {
    let state: EpisodeUpNextMenuState
    let onPlayNext: () -> Void
    let onPlayLast: () -> Void

    var body: some View {
        Button(
            "Play Next",
            systemImage: "text.line.first.and.arrowtriangle.forward",
            action: onPlayNext
        )
        .disabled(!state.canEnqueue)
        Button(
            "Play Last",
            systemImage: "text.line.last.and.arrowtriangle.forward",
            action: onPlayLast
        )
        .disabled(!state.canEnqueue)
    }
}
