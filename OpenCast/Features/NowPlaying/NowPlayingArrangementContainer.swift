import SwiftUI

/// One container for the card, the split and the tall open display: the
/// player first, the pane beside it second when there is one, each placed at
/// its allocation. A change between those arrangements moves the player; it
/// never rebuilds it, so the player's state survives the pose change.
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
