import SwiftUI

/// The request: a typed playlist idea or suggested groups. The footer says
/// what the request will send, every time, before anything leaves the device.
struct PlaylistOrganizerRequestForm: View {
    @Binding var requestText: String
    @Binding var suggestsGroups: Bool
    /// How much of the show the current choice looks through; nil until it is counted.
    let scope: PlaylistOrganizerScope?
    let canAsk: Bool
    let onAsk: () -> Void

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
                .disabled(suggestsGroups)
                .accessibilityIdentifier("Playlist Organizer Request Field")

                Toggle(PlaylistOrganizerCopy.suggestToggleTitle, isOn: $suggestsGroups)
                    .accessibilityIdentifier("Playlist Organizer Suggest Toggle")
            } header: {
                Text(PlaylistOrganizerCopy.fieldTitle)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let scope {
                        Text(PlaylistOrganizerCopy.formScope(scope))
                            .accessibilityIdentifier("Playlist Organizer Scope")
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
