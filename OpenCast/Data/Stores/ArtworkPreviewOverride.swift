import Observation

/// Per-key (episode or feed) resolved-artwork-preview box. Rows observe their
/// own key's box instead of a store-wide map, so one row resolving its preview
/// invalidates only that key's appearances (the `FeedRefreshActivity`
/// granularity precedent in `LibraryStore`).
@Observable
final class ArtworkPreviewOverride {
    var preview: ArtworkPreview?
}
