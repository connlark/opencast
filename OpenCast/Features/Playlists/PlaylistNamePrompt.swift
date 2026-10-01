import SwiftUI

/// The one alert that names playlists, for both creating and renaming. The
/// confirm button stays disabled until the trimmed name has a character, and
/// `onCommit` receives the trimmed name.
struct PlaylistNamePrompt: ViewModifier {
    @Binding var request: PlaylistNamePromptRequest?
    let onCommit: (PlaylistNamePromptRequest, String) -> Void

    @State private var name = ""
    // An alert's title is fixed per call; keeping the last one stops a
    // dismissing Rename alert from flashing the New Playlist title.
    @State private var lastTitle = PlaylistNamePromptRequest.create().title

    func body(content: Content) -> some View {
        content
            .alert(request?.title ?? lastTitle, item: $request) { request in
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                Button(request.confirmTitle) {
                    commit(request)
                }
                .disabled(trimmedName.isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: request, initial: true) { _, request in
                guard let request else {
                    return
                }
                name = request.initialName
                lastTitle = request.title
            }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ request: PlaylistNamePromptRequest) {
        let trimmedName = trimmedName
        guard !trimmedName.isEmpty else {
            return
        }
        onCommit(request, trimmedName)
    }
}

extension View {
    func playlistNamePrompt(
        _ request: Binding<PlaylistNamePromptRequest?>,
        onCommit: @escaping (PlaylistNamePromptRequest, String) -> Void
    ) -> some View {
        modifier(PlaylistNamePrompt(request: request, onCommit: onCommit))
    }
}
