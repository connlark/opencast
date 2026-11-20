import SwiftUI

/// The scope bar ignores per-item styling, `selectionDisabled` and title updates while active,
/// so a degraded index cannot grey Full Text live; the label reflects availability only when the
/// bar is created.
struct EpisodeSearchScopePicker: View {
    var isFullTextAvailable = true

    var body: some View {
        ForEach(EpisodeSearchMode.allCases) { mode in
            Text(title(for: mode)).tag(mode)
        }
    }

    private func title(for mode: EpisodeSearchMode) -> String {
        if mode == .fullText, !isFullTextAvailable {
            return "Full Text (Updating)"
        }
        return mode.title
    }
}
