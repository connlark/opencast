import Foundation
import OpenCastTranscription

/// Single-file result artifact for quiet Release benchmark runs.
/// Written once per lifecycle transition, never during a timed transcription.
nonisolated struct TranscriptionBenchmarkReport: Codable, Sendable {
    var schemaVersion: Int
    var status: String
    var runLabel: String?
    var commit: String?
    var notes: String?
    var createdAt: Date
    var completedAt: Date?

    var deviceModelIdentifier: String?
    var systemVersion: String?
    var buildConfiguration: String
    var appVersion: String?
    var appBuild: String?

    var modelIdentifier: String?
    var modelVersion: String?
    var modelTreeSHA256: String?
    var modelByteCount: Int64?
    var computeProfile: String?

    var feedURL: String
    var episodeTitle: String?
    var episodeID: String?
    var sourceAudioURL: String?
    var sourceFilePath: String?
    var sourceFileByteCount: Int64?
    var sourceFileSHA256: String?
    var clipStart: TimeInterval?
    var clipEnd: TimeInterval?
    var languageCode: String
    var decodeOptions: [String: String]?

    var requestedRepeats: Int
    var runs: [TranscriptionBenchmarkRunResult]
    var outputsIdenticalAcrossRuns: Bool?
    var transcriptRelativePath: String?
    var errorMessage: String?

    init(feedURL: URL, languageCode: String, requestedRepeats: Int, startedAt: Date = .now) {
        schemaVersion = 1
        status = "running"
        runLabel = nil
        commit = nil
        notes = nil
        createdAt = startedAt
        completedAt = nil
        deviceModelIdentifier = nil
        systemVersion = nil
        #if DEBUG
        buildConfiguration = "Debug"
        #else
        buildConfiguration = "Release"
        #endif
        appVersion = nil
        appBuild = nil
        modelIdentifier = nil
        modelVersion = nil
        modelTreeSHA256 = nil
        modelByteCount = nil
        computeProfile = nil
        self.feedURL = feedURL.absoluteString
        episodeTitle = nil
        episodeID = nil
        sourceAudioURL = nil
        sourceFilePath = nil
        sourceFileByteCount = nil
        sourceFileSHA256 = nil
        clipStart = nil
        clipEnd = nil
        self.languageCode = languageCode
        decodeOptions = nil
        self.requestedRepeats = requestedRepeats
        runs = []
        outputsIdenticalAcrossRuns = nil
        transcriptRelativePath = nil
        errorMessage = nil
    }
}
