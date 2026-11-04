import CoreGraphics

/// What the playing stack measures of itself. Each value is read where it
/// cannot depend on the artwork's size or on the spacers the metrics insert,
/// so the fit rule settles in one pass.
nonisolated struct NowPlayingContentMeasurements: Equatable {
    /// Every rendered non-artwork child of the stack (the title block, the
    /// failure block when shown, the progress section, the transport and the
    /// utility row, each with its own padding) and the stack's spacing. Never
    /// the artwork, the source pill, the content padding or a spacer.
    var rowsHeight: CGFloat?
    /// The title block: the episode and podcast titles.
    var titleBlockHeight: CGFloat?
    /// The progress section with its own top padding.
    var progressSectionHeight: CGFloat?
}
