/// Provenance of a remotely produced transcript.
///
/// Hosted models expose no immutable revision today (`modelRevision` is nil);
/// the serving-contract and pipeline versions plus the request-settings hash
/// are what make two runs comparable.
public struct OpenCastRemoteTranscriptionModelProvenance: Codable, Sendable, Equatable {
    public var provider: String
    public var modelIdentifier: String
    public var modelRevision: String?
    public var servingContractVersion: String
    public var requestSettingsSHA256: String
    public var chunkManifestSHA256: String
    public var normalizedTranscriptSHA256: String
    public var pipelineVersion: String
    /// How the source bytes were proven (additive, pass 2):
    /// `server_device_hash_match` or `exact_device_upload`. Absent from
    /// pre-pass-2 servers, which only ever hash-matched.
    public var sourceMatchMode: String?

    public init(
        provider: String,
        modelIdentifier: String,
        modelRevision: String? = nil,
        servingContractVersion: String,
        requestSettingsSHA256: String,
        chunkManifestSHA256: String,
        normalizedTranscriptSHA256: String,
        pipelineVersion: String,
        sourceMatchMode: String? = nil
    ) {
        self.provider = provider
        self.modelIdentifier = modelIdentifier
        self.modelRevision = modelRevision
        self.servingContractVersion = servingContractVersion
        self.requestSettingsSHA256 = requestSettingsSHA256
        self.chunkManifestSHA256 = chunkManifestSHA256
        self.normalizedTranscriptSHA256 = normalizedTranscriptSHA256
        self.pipelineVersion = pipelineVersion
        self.sourceMatchMode = sourceMatchMode
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case modelIdentifier = "model_identifier"
        case modelRevision = "model_revision"
        case servingContractVersion = "serving_contract_version"
        case requestSettingsSHA256 = "request_settings_sha256"
        case chunkManifestSHA256 = "chunk_manifest_sha256"
        case normalizedTranscriptSHA256 = "normalized_transcript_sha256"
        case pipelineVersion = "pipeline_version"
        case sourceMatchMode = "source_match_mode"
    }
}
