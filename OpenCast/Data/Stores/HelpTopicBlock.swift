import Foundation

/// Index-identified wrapper so `ForEach` can render a topic's blocks in
/// document order, mirroring `EpisodeShowNotesBlock`.
nonisolated struct HelpTopicBlock: Identifiable, Equatable, Sendable {
    let id: Int
    let block: HelpBlock

    static func identify(_ blocks: [HelpBlock]) -> [HelpTopicBlock] {
        blocks.enumerated().map { HelpTopicBlock(id: $0.offset, block: $0.element) }
    }
}
