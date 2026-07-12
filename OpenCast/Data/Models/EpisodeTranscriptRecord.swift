import Foundation
import SwiftData

@Model
final class EpisodeTranscriptRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var sourceAudioURL: String = ""
    var sourceFileByteCount: Int64 = 0
    var sourceFileSHA256: String = ""
    var modelIdentifier: String = ""
    var modelVersion: String = ""
    var modelTreeSHA256: String = ""
    var languageCode: String = "en"
    var stateRawValue: String = EpisodeTranscriptState.queued.rawValue
    var audioDuration: TimeInterval = 0
    var completedDuration: TimeInterval = 0
    var checkpointCount: Int = 0
    var transcriptRelativePath: String?
    var errorMessage: String?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        episodeID: String,
        podcastID: String,
        sourceAudioURL: String,
        sourceFileByteCount: Int64 = 0,
        sourceFileSHA256: String = "",
        modelIdentifier: String = "",
        modelVersion: String = "",
        modelTreeSHA256: String = "",
        languageCode: String = "en",
        state: EpisodeTranscriptState = .queued,
        audioDuration: TimeInterval = 0,
        completedDuration: TimeInterval = 0,
        checkpointCount: Int = 0,
        transcriptRelativePath: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date.now,
        updatedAt: Date = Date.now
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.sourceAudioURL = sourceAudioURL
        self.sourceFileByteCount = sourceFileByteCount
        self.sourceFileSHA256 = sourceFileSHA256
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.modelTreeSHA256 = modelTreeSHA256
        self.languageCode = languageCode
        stateRawValue = state.rawValue
        self.audioDuration = audioDuration
        self.completedDuration = completedDuration
        self.checkpointCount = checkpointCount
        self.transcriptRelativePath = transcriptRelativePath
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var state: EpisodeTranscriptState {
        get {
            EpisodeTranscriptState(rawValue: stateRawValue) ?? .failed
        }
        set {
            stateRawValue = newValue.rawValue
        }
    }
}
