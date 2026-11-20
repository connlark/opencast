import OpenCastAnalysis

/// The package request's id is the run id.
nonisolated struct ChaptersSummaryRunRequest: Sendable {
    let runID: String
    let isResume: Bool
    /// Only a listener's Generate tap may present the key screen.
    let startedByListener: Bool
    let episodeID: String
    let podcastID: String
    let episodeTitle: String
    let transcriptFingerprint: String
    let analysisRequest: TranscriptAnalysisRequest
    /// Leaves the request id out; a resume continues only when it matches the digest its run began
    /// with.
    let inputDigest: String

    init(
        runID: String,
        isResume: Bool,
        startedByListener: Bool,
        episodeID: String,
        podcastID: String,
        episodeTitle: String,
        transcriptFingerprint: String,
        analysisRequest: TranscriptAnalysisRequest
    ) {
        self.runID = runID
        self.isResume = isResume
        self.startedByListener = startedByListener
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.episodeTitle = episodeTitle
        self.transcriptFingerprint = transcriptFingerprint
        self.analysisRequest = analysisRequest
        inputDigest = Self.inputDigest(of: analysisRequest)
    }

    static func inputDigest(of request: TranscriptAnalysisRequest) -> String {
        var unidentified = request
        unidentified.requestID = ""
        return AnalysisRunRecord.digest(JSONWriter.string(unidentified.jsonValue))
    }
}
