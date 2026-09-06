import SwiftUI

/// List only asks SwiftUI to diff the rows the reader has reached. The full
/// catalog stays available to database search, counts and playback lookup.
struct EpisodeCatalogContinuation: View {
    static let pageSize = 256
    let totalCount: Int
    @Binding var visibleCount: Int

    var body: some View {
        if visibleCount < totalCount {
            Button("Load More Episodes", action: revealNextPage)
                .frame(maxWidth: .infinity, minHeight: 44)
                .onAppear(perform: revealNextPage)
        }
    }

    private func revealNextPage() {
        visibleCount = min(totalCount, visibleCount + Self.pageSize)
    }
}
