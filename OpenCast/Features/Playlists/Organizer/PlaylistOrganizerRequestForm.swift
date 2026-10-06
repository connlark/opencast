import SwiftUI

/// The request: a typed playlist idea, or suggested groups at a tap. Each
/// path says what it will send, every time, before anything leaves the device.
struct PlaylistOrganizerRequestForm: View {
    @Binding var requestText: String
    /// How much of the show each path looks through; nil until it is counted.
    let promptedScope: PlaylistOrganizerScope?
    let suggestionScope: PlaylistOrganizerScope?
    let canAsk: Bool
    let onAsk: () -> Void
    let onSuggest: () -> Void

    var body: some View {
        Form {
            Section {
                TextField(
                    PlaylistOrganizerCopy.fieldTitle,
                    text: $requestText,
                    prompt: Text(PlaylistOrganizerCopy.fieldPlaceholder)
                )
                .submitLabel(.go)
                .onSubmit(onAsk)
                .accessibilityIdentifier("Playlist Organizer Request Field")
            } header: {
                Text(PlaylistOrganizerCopy.fieldTitle)
            } footer: {
                if let promptedScope {
                    Text(PlaylistOrganizerCopy.formScope(promptedScope))
                        .accessibilityIdentifier("Playlist Organizer Scope")
                }
            }

            Section {
                Button(PlaylistOrganizerCopy.suggestButtonTitle, systemImage: "sparkles", action: onSuggest)
                    .accessibilityIdentifier("Playlist Organizer Suggest")
            } header: {
                Text(PlaylistOrganizerCopy.suggestSectionTitle)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading) {
                        Text(PlaylistOrganizerCopy.suggestExplanation)
                        if let suggestionScope {
                            Text(PlaylistOrganizerCopy.formScope(suggestionScope))
                                .accessibilityIdentifier("Playlist Organizer Suggestion Scope")
                        }
                    }
                    Text(PlaylistOrganizerDisclosureCopy.body)
                        .accessibilityIdentifier("Playlist Organizer Disclosure")
                    HelpFooterLink(
                        title: PlaylistOrganizerCopy.helpLinkTitle,
                        topicID: HelpTopicID.playlistOrganizer
                    )
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Rides above the keyboard, so Ask stays reachable while typing.
        .safeAreaInset(edge: .bottom) {
            Button(PlaylistOrganizerCopy.askButtonTitle, action: onAsk)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canAsk)
                .accessibilityIdentifier("Playlist Organizer Ask")
                .padding()
        }
    }
}
