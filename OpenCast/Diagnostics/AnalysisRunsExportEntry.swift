import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// One analysis run as the export and the episode report show it. It reads
/// the run record's closed values and numbers only: episode and podcast ids,
/// the transcript fingerprint and the model label stay out, the outcome and
/// the listener failure are re-read through their enums, and the run id,
/// model id and policy revision must pass their grammars.
nonisolated struct AnalysisRunsExportEntry: Encodable, Sendable, Equatable {
    struct Windows: Encodable, Sendable, Equatable {
        let total: Int
        let accepted: Int
        let failed: Int
    }

    let runID: String
    let feature: String
    let route: String
    let provider: String
    let modelID: String
    let bundleVersion: Int
    let policySource: String
    let policyRevision: String
    let state: String
    let background: Bool?
    let outcomeCode: String?
    let listenerFailure: String?
    let windows: Windows
    let sends: Int
    let inputTokens: UInt64
    let outputTokens: UInt64
    let pacedSeconds: Double
    let exchangeSeconds: Double
    let startedAt: Date
    let finishedAt: Date?

    init(_ record: AnalysisRunRecord) {
        runID = AnalysisRunsExportGrammar.runID(record.id)
        feature = record.feature.rawValue
        route = record.route.rawValue
        provider = record.provider.rawValue
        modelID = AnalysisRunsExportGrammar.modelID(record.modelID)
        bundleVersion = record.bundleVersion
        policySource = record.policySource.rawValue
        policyRevision = AnalysisRunsExportGrammar.policyRevision(record.policyRevision)
        state = record.state.rawValue
        background = record.background
        outcomeCode = record.outcomeCode.map(Self.outcomeCode)
        listenerFailure = record.listenerFailure.map { raw in
            AnalysisProviderFailure(rawValue: raw)?.rawValue ?? AnalysisRunsExportGrammar.invalid
        }
        let verdicts = record.windows.values
        windows = Windows(
            total: verdicts.count,
            accepted: verdicts.count { $0.verdict == .accepted },
            failed: verdicts.count { $0.verdict == .failed }
        )
        sends = verdicts.reduce(0) { $0 + $1.sends }
        inputTokens = record.inputTokens
        outputTokens = record.outputTokens
        pacedSeconds = Self.finite(record.pacedSeconds)
        exchangeSeconds = Self.finite(record.exchangeSeconds)
        startedAt = record.startedAt
        finishedAt = record.finishedAt
    }

    /// `completed`, or a pipeline failure code.
    private static func outcomeCode(_ raw: String) -> String {
        if raw == "completed" {
            return raw
        }
        return AnalysisFailureCode(rawValue: raw)?.rawValue ?? AnalysisRunsExportGrammar.invalid
    }

    private static func finite(_ seconds: Double) -> Double {
        seconds.isFinite ? seconds : 0
    }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case feature
        case route
        case provider
        case modelID = "model_id"
        case bundleVersion = "bundle_version"
        case policySource = "policy_source"
        case policyRevision = "policy_revision"
        case state
        case background
        case outcomeCode = "outcome_code"
        case listenerFailure = "listener_failure"
        case windows
        case sends
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case pacedSeconds = "paced_seconds"
        case exchangeSeconds = "exchange_seconds"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    /// Optional fields encode as `null` so every entry has the same keys.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(feature, forKey: .feature)
        try container.encode(route, forKey: .route)
        try container.encode(provider, forKey: .provider)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(bundleVersion, forKey: .bundleVersion)
        try container.encode(policySource, forKey: .policySource)
        try container.encode(policyRevision, forKey: .policyRevision)
        try container.encode(state, forKey: .state)
        try container.encode(background, forKey: .background)
        try container.encode(outcomeCode, forKey: .outcomeCode)
        try container.encode(listenerFailure, forKey: .listenerFailure)
        try container.encode(windows, forKey: .windows)
        try container.encode(sends, forKey: .sends)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(pacedSeconds, forKey: .pacedSeconds)
        try container.encode(exchangeSeconds, forKey: .exchangeSeconds)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
    }
}
