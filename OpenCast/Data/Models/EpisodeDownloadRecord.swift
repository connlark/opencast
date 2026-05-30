import Foundation
import SwiftData

@Model
final class EpisodeDownloadRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var sourceAudioURL: String = ""
    var localRelativePath: String?
    var stateRawValue: String = EpisodeDownloadState.downloading.rawValue
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64?
    var errorMessage: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        episodeID: String,
        podcastID: String,
        sourceAudioURL: String,
        localRelativePath: String? = nil,
        state: EpisodeDownloadState = .downloading,
        bytesReceived: Int64 = 0,
        bytesExpected: Int64? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.sourceAudioURL = sourceAudioURL
        self.localRelativePath = localRelativePath
        stateRawValue = state.rawValue
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var state: EpisodeDownloadState {
        get {
            EpisodeDownloadState(rawValue: stateRawValue) ?? .failed
        }
        set {
            stateRawValue = newValue.rawValue
        }
    }
}
