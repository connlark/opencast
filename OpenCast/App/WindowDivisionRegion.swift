import SwiftUI

/// One `.division` reserved region (a fold band) as `WindowPose` reads it.
/// `ReservedRegion` has no public initializer, so the pose model and its tests
/// take this value instead of the SDK type.
nonisolated struct WindowDivisionRegion: Equatable, Sendable {
    /// In the reading proxy's local coordinate space.
    var frame: CGRect
    var isActive: Bool

    init(frame: CGRect, isActive: Bool) {
        self.frame = frame
        self.isActive = isActive
    }

    init(_ region: ReservedRegion) {
        self.init(frame: region.frame, isActive: region.isActive)
    }

    /// The proxy's CURRENT `.division` regions. Read it on every layout (in a
    /// `GeometryReader` body) and never cache it: the first layout after
    /// launch reports none, and a later layout reports the fold.
    static func current(in proxy: GeometryProxy) -> [WindowDivisionRegion] {
        proxy.reservedRegions(kind: .division).map(Self.init)
    }

    /// Active, with a finite origin and a positive, finite width and height.
    /// `CGRect.width` and `height` standardize a negative size, so the raw
    /// `size` is checked; `CGRect.infinite` is stored as huge finite numbers,
    /// so it is excluded by name.
    var isUsable: Bool {
        isActive
            && !frame.isInfinite
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
            && area.isFinite
    }

    var area: Double {
        frame.size.width * frame.size.height
    }
}
