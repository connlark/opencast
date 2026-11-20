import Foundation
import SwiftData

/// `#Predicate` cannot abstract over protocol key paths, so fetches stay in the concrete
/// stores. Nonisolated: a main-actor protocol would infer isolation onto the models and make
/// their key paths non-Sendable inside `FetchDescriptor`.
nonisolated protocol TranscriptDerivedAnalysisRecord: PersistentModel {
    var episodeID: String { get set }
    var podcastID: String { get set }
    var state: EpisodeAnalysisRecordState { get set }
    var transcriptFingerprint: String { get set }
    var transcriptUpdatedAt: Date { get set }
    var transcriptSegmentCount: Int { get set }
    var analysisRelativePath: String? { get set }
    var errorMessage: String? { get set }
    var failureKind: EpisodeAnalysisFailureKind? { get set }
    var jobAcceptedAt: Date? { get set }
    var createdAt: Date { get }
    var updatedAt: Date { get set }
}
