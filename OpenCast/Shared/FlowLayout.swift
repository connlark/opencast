import SwiftUI

/// Wraps its subviews into centred lines, left to right, like words in a
/// paragraph. A subview wider than a line is offered the line's width and
/// never reported wider than it; a nil proposed width lays everything out on
/// one line. `Layout` is not main-actor isolated, so neither is this type or
/// anything its witnesses call.
nonisolated struct FlowLayout: Layout {
    var spacing: Double = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arrangement = arrangement(of: subviews, maxWidth: proposal.width)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for line in arrangement.lines {
            width = max(width, lineWidth(line, sizes: arrangement.sizes))
            height += lineHeight(line, sizes: arrangement.sizes)
        }
        height += CGFloat(spacing) * CGFloat(max(0, arrangement.lines.count - 1))
        return CGSize(width: width, height: height)
    }

    // Lines are rebuilt from the proposal, not the bounds, so placement
    // breaks exactly where `sizeThatFits` did; the bounds only centre them.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrangement(of: subviews, maxWidth: proposal.width)
        let gap = CGFloat(spacing)
        var y = bounds.minY
        for line in arrangement.lines {
            let height = lineHeight(line, sizes: arrangement.sizes)
            var x = bounds.minX + (bounds.width - lineWidth(line, sizes: arrangement.sizes)) / 2
            for offset in line {
                let size = arrangement.sizes[offset]
                subviews[subviews.startIndex + offset].place(
                    at: CGPoint(x: x, y: y + (height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + gap
            }
            y += height + gap
        }
    }

    /// Each subview's size and the offset ranges of the lines, filled
    /// greedily. A line always takes at least one subview, so a zero width
    /// yields one subview per line.
    private func arrangement(
        of subviews: Subviews,
        maxWidth: CGFloat?
    ) -> (sizes: [CGSize], lines: [Range<Int>]) {
        let limit = maxWidth ?? .infinity
        let gap = CGFloat(spacing)
        var sizes: [CGSize] = []
        sizes.reserveCapacity(subviews.count)
        var lines: [Range<Int>] = []
        var lineStart = 0
        var currentWidth: CGFloat = 0

        for (offset, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > limit {
                size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                size.width = min(size.width, limit)
            }
            sizes.append(size)

            if offset == lineStart {
                currentWidth = size.width
            } else if currentWidth + gap + size.width > limit {
                lines.append(lineStart..<offset)
                lineStart = offset
                currentWidth = size.width
            } else {
                currentWidth += gap + size.width
            }
        }
        if lineStart < sizes.count {
            lines.append(lineStart..<sizes.count)
        }
        return (sizes, lines)
    }

    private func lineWidth(_ line: Range<Int>, sizes: [CGSize]) -> CGFloat {
        var width = CGFloat(spacing) * CGFloat(max(0, line.count - 1))
        for offset in line {
            width += sizes[offset].width
        }
        return width
    }

    private func lineHeight(_ line: Range<Int>, sizes: [CGSize]) -> CGFloat {
        var height: CGFloat = 0
        for offset in line {
            height = max(height, sizes[offset].height)
        }
        return height
    }
}
