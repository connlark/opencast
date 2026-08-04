import OpenCastPlayback
import SwiftUI

struct OpenCastCommandActions {
    let togglePlayback: () -> Void
    let seekBackward: () -> Void
    let seekForward: () -> Void
    let focusSearch: () -> Void

    static func make(
        playback: AVFoundationPlaybackController,
        focusSearch: @escaping () -> Void
    ) -> OpenCastCommandActions {
        OpenCastCommandActions(
            togglePlayback: playback.togglePlayPause,
            seekBackward: {
                playback.skip(by: -playback.skipBackwardInterval)
            },
            seekForward: {
                playback.skip(by: playback.skipForwardInterval)
            },
            focusSearch: focusSearch
        )
    }
}

extension FocusedValues {
    @Entry var openCastCommandActions: OpenCastCommandActions?
}

struct OpenCastCommands: Commands {
    @FocusedValue(\.openCastCommandActions) private var actions

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search") {
                actions?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil)
        }

        CommandMenu("Playback") {
            Button("Play or Pause") {
                actions?.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(actions == nil)

            Button("Seek Backward") {
                actions?.seekBackward()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(actions == nil)

            Button("Seek Forward") {
                actions?.seekForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(actions == nil)
        }
    }
}
