import SwiftUI

/// List only asks SwiftUI to diff the rows the reader has reached. The full
/// catalog stays available to database search, counts and playback lookup.
/// Callers with a filtered prefix can provide `hasMore` instead of a total.
struct EpisodeCatalogContinuation: View {
    static let pageSize = 256
    private let totalCount: Int?
    private let hasMore: Bool?
    @Binding var visibleCount: Int

    init(totalCount: Int, visibleCount: Binding<Int>) {
        self.totalCount = totalCount
        hasMore = nil
        _visibleCount = visibleCount
    }

    init(hasMore: Bool, visibleCount: Binding<Int>) {
        totalCount = nil
        self.hasMore = hasMore
        _visibleCount = visibleCount
    }

    var body: some View {
        if shouldShowMore {
            Button("Load More Episodes", action: revealNextPage)
                .frame(maxWidth: .infinity, minHeight: 44)
                .onAppear(perform: revealNextPage)
        }
    }

    private var shouldShowMore: Bool {
        if let hasMore {
            return hasMore
        }
        return visibleCount < (totalCount ?? 0)
    }

    private func revealNextPage() {
        let nextVisibleCount = visibleCount + Self.pageSize
        if let totalCount {
            visibleCount = min(totalCount, nextVisibleCount)
        } else {
            visibleCount = nextVisibleCount
        }
    }
}
