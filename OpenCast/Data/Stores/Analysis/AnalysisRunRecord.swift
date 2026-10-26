import CryptoKit
import Foundation
import OpenCastAnalysis

/// The durable record of one analysis run, written before the run's first
/// dispatch and updated at every send and at the end. It holds ids, closed
/// values and numbers only: no key, no transcript or provider text, no URL.
/// A run killed after dispatch resumes under the same id, so the trial
/// service counts it once.
nonisolated struct AnalysisRunRecord: Codable, Sendable, Hashable, Identifiable {
    enum State: String, Codable, Sendable, Hashable {
        /// Written before the first send; still running, or killed.
        case dispatched
        case finished
        case failed
        /// The continued-processing card expired; resumable.
        case expired
        case cancelled
    }

    enum Route: String, Codable, Sendable, Hashable {
        case direct
        case trial
    }

    enum PolicySource: String, Codable, Sendable, Hashable {
        case baked
        case downloaded
    }

    /// What the run's sends say about one ad-detection window (Chapters
    /// keeps window 0).
    enum WindowVerdict: String, Codable, Sendable, Hashable {
        /// The first request is out.
        case dispatched
        /// The latest send of the window got an answer.
        case answered
        /// The corrective request is out.
        case repairing
        /// The finished run accepted the window.
        case accepted
        /// The window ended the run.
        case failed
        /// The run stopped before the window finished.
        case cancelled
    }

    struct Window: Codable, Sendable, Hashable {
        var verdict: WindowVerdict
        var sends: Int
    }

    let id: String
    let feature: AnalysisFeature
    /// The app's episode id (itself a digest).
    let episodeID: String
    /// SHA-256 of the podcast id, which is a feed URL and may carry
    /// credentials; never the id itself.
    let podcastDigest: String
    let transcriptFingerprint: String
    /// SHA-256 of everything the run's result depends on besides the
    /// provider's replies (the whole request, timings and durations
    /// included); a resume must match it.
    let inputDigest: String?
    let route: Route
    let provider: AnalysisProvider
    let modelID: String
    let modelLabel: String
    let bundleVersion: Int
    let policySource: PolicySource
    let policyRevision: String
    let startedAt: Date
    var state: State
    /// Keyed by the window index as a decimal string.
    var windows: [String: Window]
    var inputTokens: UInt64
    var outputTokens: UInt64
    var pacedSeconds: Double
    var exchangeSeconds: Double
    /// `completed`, or the run's failure code (`AnalysisFailureCode`).
    var outcomeCode: String?
    /// The listener-facing failure (`AnalysisProviderFailure` raw value).
    var listenerFailure: String?
    /// Whether a continued-processing card held the run when it finished.
    var background: Bool?
    /// Whether the run's token totals are saved in the listener's usage
    /// (direct runs); a run that ended without it is counted at the next
    /// launch.
    var usageRecorded: Bool?
    var finishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case feature
        case episodeID = "episode_id"
        case podcastDigest = "podcast_digest"
        case transcriptFingerprint = "transcript_fingerprint"
        case inputDigest = "input_digest"
        case route
        case provider
        case modelID = "model_id"
        case modelLabel = "model_label"
        case bundleVersion = "bundle_version"
        case policySource = "policy_source"
        case policyRevision = "policy_revision"
        case startedAt = "started_at"
        case state
        case windows
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case pacedSeconds = "paced_seconds"
        case exchangeSeconds = "exchange_seconds"
        case outcomeCode = "outcome_code"
        case listenerFailure = "listener_failure"
        case background
        case usageRecorded = "usage_recorded"
        case finishedAt = "finished_at"
    }
}

nonisolated extension AnalysisRunRecord {
    /// A new record for a run about to dispatch.
    init(
        id: String = UUID().uuidString,
        feature: AnalysisFeature,
        episodeID: String,
        podcastID: String,
        transcriptFingerprint: String,
        inputDigest: String? = nil,
        resolution: AnalysisRouteResolution,
        policy: AnalysisRoutePolicy,
        startedAt: Date = .now
    ) {
        self.id = id
        self.feature = feature
        self.episodeID = episodeID
        podcastDigest = Self.digest(podcastID)
        self.transcriptFingerprint = transcriptFingerprint
        self.inputDigest = inputDigest
        route = if case .direct = resolution.route { .direct } else { .trial }
        provider = resolution.provider ?? policy.model.provider
        modelID = policy.model.modelID
        modelLabel = policy.model.label
        bundleVersion = policy.bundleVersion
        policySource = if case .downloaded = policy.source { .downloaded } else { .baked }
        policyRevision = policy.revision
        self.startedAt = startedAt
        state = .dispatched
        windows = [:]
        inputTokens = 0
        outputTokens = 0
        pacedSeconds = 0
        exchangeSeconds = 0
    }
}

nonisolated extension AnalysisRunRecord {
    /// Lowercase hex SHA-256 of `text`'s UTF-8 bytes.
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
