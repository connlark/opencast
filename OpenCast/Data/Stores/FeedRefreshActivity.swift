import Observation

/// One object per feed: a store-wide set would invalidate every row when one feed turns busy.
@Observable
final class FeedRefreshActivity {
    var isRefreshing = false
}
