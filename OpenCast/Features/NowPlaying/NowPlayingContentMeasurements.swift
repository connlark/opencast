import CoreGraphics

/// Each value is measured where the artwork's size and the metrics' spacers cannot reach it,
/// so the fit rule settles in one pass.
nonisolated struct NowPlayingContentMeasurements: Equatable {
    /// Every non-artwork child of the stack, each with its own padding, plus the stack's spacing;
    /// never the artwork, the source pill, the content padding or a spacer.
    var rowsHeight: CGFloat?
    var titleBlockHeight: CGFloat?
    /// The progress section with its own top padding.
    var progressSectionHeight: CGFloat?
}
