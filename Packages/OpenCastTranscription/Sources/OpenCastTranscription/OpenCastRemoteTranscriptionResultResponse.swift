public struct OpenCastRemoteTranscriptionResultResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var result: OpenCastRemoteTranscriptionResult
    /// Present only on jobs created with `adAnalysisRequested`.
    public var adAnalysis: OpenCastRemoteTranscriptionAdAnalysisOutcome?

    public init(
        schemaVersion: Int,
        result: OpenCastRemoteTranscriptionResult,
        adAnalysis: OpenCastRemoteTranscriptionAdAnalysisOutcome? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.result = result
        self.adAnalysis = adAnalysis
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case result
        case adAnalysis = "ad_analysis"
    }
}
