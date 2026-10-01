import SwiftUI

/// A request that produced no proposals, with the next steps that suit it:
/// the same request again, the other mode, or back to the typed request.
struct PlaylistOrganizerOutcomeView: View {
    let outcome: PlaylistOrganizerOutcome
    let mode: PlaylistOrganizerMode
    let onTryAgain: () -> Void
    let onOtherMode: () -> Void
    let onEditRequest: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
        } description: {
            Text(outcome.message(for: mode) ?? "")
            // "No matching episodes" is only true of the part the model saw.
            if case .empty(let scope) = outcome {
                Text(PlaylistOrganizerCopy.resultScope(scope))
                    .font(.footnote)
            }
        } actions: {
            if outcome.offersRetry {
                Button(PlaylistOrganizerCopy.tryAgain, action: onTryAgain)
                    .buttonStyle(.glassProminent)
            }
            if outcome.offersOtherMode {
                Button(otherModeTitle, action: onOtherMode)
            }
            // Both prompted messages that offer the other mode also say
            // "Try different words".
            if mode == .prompted, outcome.offersOtherMode {
                Button("Edit Request", action: onEditRequest)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Playlist Organizer Outcome")
    }

    private var isEmpty: Bool {
        if case .empty = outcome {
            true
        } else {
            false
        }
    }

    private var title: String {
        isEmpty ? PlaylistOrganizerCopy.emptyTitle : PlaylistOrganizerCopy.outcomeTitle
    }

    private var symbolName: String {
        isEmpty ? "music.note.list" : "exclamationmark.bubble"
    }

    private var otherModeTitle: String {
        switch mode {
        case .prompted:
            PlaylistOrganizerCopy.suggestGroupsInstead
        case .unprompted:
            PlaylistOrganizerCopy.askForPlaylistInstead
        }
    }
}
