import SwiftUI

struct EpisodeSearchScopePicker: View {
    var body: some View {
        ForEach(EpisodeSearchMode.allCases) { mode in
            Text(mode.title).tag(mode)
        }
    }
}
