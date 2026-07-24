/// Response of `jobs/{id}/result`. Served with `Cache-Control: no-store`;
/// the result object is deleted on acknowledgement.
public struct OpenCastRemoteTranscriptionResultResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var result: OpenCastRemoteTranscriptionResult
    /// Present only on jobs created with `adAnalysisRequested`; the transcript
    /// subtree is byte-identical whether or not this key exists.
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
