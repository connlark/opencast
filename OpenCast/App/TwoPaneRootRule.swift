import SwiftUI

nonisolated enum TwoPaneRootContainer: String, Equatable, Sendable {
    case split
    case stack
}

nonisolated enum TwoPaneRootRule {
    static func container(pose: WindowPose, isFoldableScene: Bool, windowSize: CGSize) -> TwoPaneRootContainer {
        guard isFoldableScene else {
            return .stack
        }
        switch pose {
        case .foldedVertical:
            return .split
        case .regularFlat:
            return windowSize.width > windowSize.height ? .split : .stack
        case .compact, .foldedHorizontal:
            return .stack
        }
    }
}
