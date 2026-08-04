import Observation

/// Per-feed refresh busy flag. Subscription rows observe their own feed's
/// activity object instead of a store-wide set, so marking one feed busy
/// invalidates only that feed's rows (the `progressIndexRevision`
/// granularity precedent in `LibraryStore`).
@Observable
final class FeedRefreshActivity {
    var isRefreshing = false
}
