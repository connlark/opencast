import SwiftUI

struct PlaylistOrganizerOutcomeView: View {
    let outcome: PlaylistOrganizerOutcome
    let mode: PlaylistOrganizerMode
    let answerStyle: PlaylistOrganizerAnswerStyle
    let onTryAgain: () -> Void
    let onTrySimpler: () -> Void
    let onOtherMode: () -> Void
    let onEditRequest: () -> Void

    var body: some View {
        // Up to five actions can outgrow a sheet at the largest text sizes, so this scrolls, and
        // it stays centred whenever it fits.
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
    }

    private var content: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
        } description: {
            Text(outcome.message(for: mode, answerStyle: answerStyle) ?? "")
            // "No matching episodes" is only true of the part the model saw.
            if case .empty(let scope) = outcome {
                Text(PlaylistOrganizerCopy.resultScope(scope))
                    .font(.footnote)
                if answerStyle == .indicesOnly {
                    Label(PlaylistOrganizerCopy.simplerResult, systemImage: "flask")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .accessibilityIdentifier("Playlist Organizer Simpler Answer Note")
                }
            }
        } actions: {
            if outcome.offersRetry {
                Button(PlaylistOrganizerCopy.tryAgain, action: onTryAgain)
                    .buttonStyle(.glassProminent)
            }
            if offersSimplerRetry {
                VStack(spacing: 4) {
                    Button(PlaylistOrganizerCopy.retrySimpler, systemImage: "flask", action: onTrySimpler)
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("Playlist Organizer Retry Simpler")
                    // VoiceOver reads it right after the button, so the
                    // button carries no hint repeating it.
                    Text(PlaylistOrganizerCopy.simplerRetryFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("Playlist Organizer Simpler Footnote")
                }
            }
            if outcome.offersOtherMode {
                Button(otherModeTitle, action: onOtherMode)
            }
            // Both prompted messages that offer the other mode also say
            // "Try different words".
            if mode == .prompted, outcome.offersOtherMode {
                Button(PlaylistOrganizerCopy.editRequest, action: onEditRequest)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Playlist Organizer Outcome")
    }

    private var offersSimplerRetry: Bool {
        outcome.offersSimplerRetry && answerStyle == .standard
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
