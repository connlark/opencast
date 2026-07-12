import Foundation

struct EpisodePipelineStep: Equatable, Identifiable {
    let kind: EpisodePipelineStepKind
    let status: EpisodePipelineStepStatus

    var id: EpisodePipelineStepKind {
        kind
    }
}
