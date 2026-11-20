import Observation

/// One box per episode or feed key, so a row resolving its preview invalidates only that key's
/// views instead of every reader of a store-wide map.
@Observable
final class ArtworkPreviewOverride {
    var preview: ArtworkPreview?
}
