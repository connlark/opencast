import SwiftUI

/// One Layout for every arrangement, so a pose change moves the player instead of rebuilding
/// it and its state survives.
nonisolated struct NowPlayingArrangementContainer: Layout {
    let allocations: NowPlayingAllocations

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = [allocations.player] + (allocations.pane.map { [$0] } ?? [])
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}
