import SwiftUI

/// The search-scope bar ignores per-item styling, `selectionDisabled`, and
/// in-place title updates on an active bar, so the degraded-index state cannot
/// grey the Full Text segment live; `SearchIndexUpdatingIndicator` carries
/// that affordance in the results. The label here still reflects availability
/// whenever the scope bar is (re)created, and selecting Full Text stays
/// allowed — the session bounds results to visible fields either way.
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
