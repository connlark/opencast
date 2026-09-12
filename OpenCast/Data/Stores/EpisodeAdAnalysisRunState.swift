import Foundation
import OpenCastTranscription

/// Device-local recovery metadata. Kept beside the episode's documents so
/// delete/migration follows the same lifecycle without a synced model change.
nonisolated struct EpisodeAdAnalysisRunState: Codable, Sendable, Equatable {
    var transcriptFingerprint: String
    var jobID: String?
    var replayIdentity: String?
    var failure: OpenCastAdAnalysisFailure?
    var failureCode: String?
    var previousAnalysisPath: String?

    @concurrent
    static func inputIdentity(_ transcript: EpisodeTranscriptDocument) async throws -> String {
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(transcript.segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // No import timestamp: re-importing identical source/ASR output must
        // not turn an exhausted model answer into an automatic paid replay.
        let bytes = try encoder.encode(segments)
        let source = [transcript.sourceFileSHA256, "\(transcript.sourceFileByteCount)",
                      "\(transcript.audioDuration)", transcript.languageCode,
                      transcript.modelIdentifier, transcript.modelVersion, transcript.modelTreeSHA256]
        return OpenCastSHA256.hash(bytes + (try encoder.encode(source)))
    }
}

extension EpisodeAdAnalysisFileStore {
    nonisolated func readRunState(episodeID: String) throws -> EpisodeAdAnalysisRunState? {
        do {
            return try JSONDecoder().decode(EpisodeAdAnalysisRunState.self, from: Data(contentsOf: runStateURL(episodeID)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    nonisolated func writeRunState(_ state: EpisodeAdAnalysisRunState, episodeID: String) throws {
        try prepareAnalysesDirectory()
        let url = runStateURL(episodeID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private nonisolated func runStateURL(_ episodeID: String) -> URL {
        analysesDirectory.appending(path: safeStem(episodeID)).appending(path: "run-state.json")
    }
}
