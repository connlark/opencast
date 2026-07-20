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
    var entityTag: String?
    var lastModifiedHeader: String?
    /// SHA-256 of the completed assembled file; empty until a download
    /// completes and cleared whenever the file is re-downloaded or fails.
    /// Header validators never substitute for this hash.
    var sourceFileSHA256: String = ""
    var episodeTitle: String?
    var podcastTitle: String?
    var artworkURLString: String?
    var duration: TimeInterval?
    var publishedAt: Date?
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
        entityTag: String? = nil,
        lastModifiedHeader: String? = nil,
        episodeTitle: String? = nil,
        podcastTitle: String? = nil,
        artworkURLString: String? = nil,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil,
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
        self.entityTag = entityTag
        self.lastModifiedHeader = lastModifiedHeader
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.artworkURLString = artworkURLString
        self.duration = duration
        self.publishedAt = publishedAt
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
