import OpenCastAnalysis

/// One Chapters & Summary run as the store hands it to the producer: the
/// package request (its request id is the run id) plus what the run record
/// and the continued-processing card need. Built off the main actor.
nonisolated struct ChaptersSummaryRunRequest: Sendable {
    let runID: String
    /// True when the run continues an interrupted one with the same id.
    let isResume: Bool
    /// A Generate tap, not a launch or activation resume: only a listener
    /// action may present the key screen.
    let startedByListener: Bool
    let episodeID: String
    let podcastID: String
    let episodeTitle: String
    let transcriptFingerprint: String
    let analysisRequest: TranscriptAnalysisRequest
    /// SHA-256 of the package request with its request id left out: what a
    /// resumed run's result depends on besides the replies it kept. A resume
    /// continues only when it matches the digest its run began with.
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
