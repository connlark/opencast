import Foundation
import SwiftData

@Model
final class EpisodeTranscriptAnalysisRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var transcriptFingerprint: String = ""
    var transcriptUpdatedAt: Date = Date.distantPast
    var transcriptSegmentCount: Int = 0
    var transcriptStateRawValue: String = EpisodeTranscriptState.completed.rawValue
    var stateRawValue: String = EpisodeAnalysisRecordState.queued.rawValue
    var analysisRelativePath: String?
    var model: String = ""
    var policy: String = ""
    var chapterCount: Int = 0
    var warningCount: Int = 0
    var errorMessage: String?
    var failureKindRawValue: String?
    var jobAcceptedAt: Date?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        episodeID: String,
        podcastID: String,
        transcriptFingerprint: String = "",
        transcriptUpdatedAt: Date = .distantPast,
        transcriptSegmentCount: Int = 0,
        transcriptState: EpisodeTranscriptState = .completed,
        state: EpisodeAnalysisRecordState = .queued,
        analysisRelativePath: String? = nil,
        model: String = "",
        policy: String = "",
        chapterCount: Int = 0,
        warningCount: Int = 0,
        errorMessage: String? = nil,
        jobAcceptedAt: Date? = nil,
        createdAt: Date = Date.now,
        updatedAt: Date = Date.now
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.transcriptFingerprint = transcriptFingerprint
        self.transcriptUpdatedAt = transcriptUpdatedAt
        self.transcriptSegmentCount = transcriptSegmentCount
        transcriptStateRawValue = transcriptState.rawValue
        stateRawValue = state.rawValue
        self.analysisRelativePath = analysisRelativePath
        self.model = model
        self.policy = policy
        self.chapterCount = chapterCount
        self.warningCount = warningCount
        self.errorMessage = errorMessage
        self.jobAcceptedAt = jobAcceptedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var state: EpisodeAnalysisRecordState {
        get {
            EpisodeAnalysisRecordState(rawValue: stateRawValue) ?? .failed
        }
        set {
            stateRawValue = newValue.rawValue
        }
    }

    var transcriptState: EpisodeTranscriptState {
        get {
            EpisodeTranscriptState(rawValue: transcriptStateRawValue) ?? .interrupted
        }
        set {
            transcriptStateRawValue = newValue.rawValue
        }
    }

    var failureKind: EpisodeAnalysisFailureKind? {
        get {
            failureKindRawValue.flatMap(EpisodeAnalysisFailureKind.init(rawValue:))
        }
        set {
            failureKindRawValue = newValue?.rawValue
        }
    }
}

extension EpisodeTranscriptAnalysisRecord: TranscriptDerivedAnalysisRecord {}
