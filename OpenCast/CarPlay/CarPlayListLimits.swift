/// The per-template ceilings the connected head unit reports. Every list is
/// sliced to these before it reaches CarPlay, which drops extra items silently.
nonisolated struct CarPlayListLimits: Equatable, Sendable {
    /// The floor CarPlay guarantees for audio apps. Used when the framework
    /// reports nothing usable, so a list is never rendered unbounded.
    static let fallback = CarPlayListLimits(maximumItemCount: 12, maximumSectionCount: 2)

    let maximumItemCount: Int
    let maximumSectionCount: Int
    /// Now Playing can already sit at the fourth level of the five-template
    /// stack, so a list pushed from it has no room left to reach a further page.
    let allowsContinuation: Bool

    /// The same ceilings, spending every visible slot on content because a
    /// "Show More" row would have nowhere to go.
    var withoutContinuation: CarPlayListLimits {
        CarPlayListLimits(
            maximumItemCount: maximumItemCount,
            maximumSectionCount: maximumSectionCount,
            allowsContinuation: false
        )
    }

    init(maximumItemCount: Int, maximumSectionCount: Int, allowsContinuation: Bool = true) {
        self.maximumItemCount = max(maximumItemCount, 1)
        self.maximumSectionCount = max(maximumSectionCount, 1)
        self.allowsContinuation = allowsContinuation
    }
}
