/// CarPlay silently drops list items past these ceilings.
nonisolated struct CarPlayListLimits: Equatable, Sendable {
    /// The floor CarPlay guarantees audio apps, for when the framework reports nothing usable.
    static let fallback = CarPlayListLimits(maximumItemCount: 12, maximumSectionCount: 2)

    let maximumItemCount: Int
    let maximumSectionCount: Int
    /// Now Playing can already sit at the fourth level of the five-template
    /// stack, so a list pushed from it has no room left to reach a further page.
    let allowsContinuation: Bool

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
