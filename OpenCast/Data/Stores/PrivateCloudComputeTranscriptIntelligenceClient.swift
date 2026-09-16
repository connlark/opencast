import Foundation
import FoundationModels

/// The production client over `PrivateCloudComputeLanguageModel`. The model
/// handle is created on first use so app-model construction in tests and on
/// the simulator never touches Foundation Models.
nonisolated final class PrivateCloudComputeTranscriptIntelligenceClient: TranscriptIntelligenceModelClient {
    private lazy var model = PrivateCloudComputeLanguageModel()

    init() {}

    /// PCC exposes no model version; the OS release is the closest proxy for
    /// when Apple's served model can change.
    var modelIdentifier: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "private-cloud-compute/\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    var modelAvailability: TranscriptIntelligenceModelAvailability {
        if case .unavailable(.deviceNotEligible) = model.availability {
            return .deviceNotEligible
        }
        // PCC does not report the Apple Intelligence switch; the on-device
        // model does, and PCC needs it on as well.
        if case .unavailable(.appleIntelligenceNotEnabled) = SystemLanguageModel.default.availability {
            return .appleIntelligenceNotEnabled
        }
        switch model.availability {
        case .available:
            return .available
        case .unavailable:
            return .systemNotReady
        }
    }

    var quota: TranscriptIntelligenceQuotaSnapshot {
        let usage = model.quotaUsage
        var snapshot = TranscriptIntelligenceQuotaSnapshot(
            isLimitReached: usage.isLimitReached,
            resetDate: usage.resetDate,
            hasLimitIncreaseSuggestion: usage.limitIncreaseSuggestion != nil
        )
        if case .belowLimit(let below) = usage.status {
            snapshot.isApproachingLimit = below.isApproachingLimit
        }
        return snapshot
    }

    /// The on-device tokenizer matches PCC's count within 0.1 %, so prompts
    /// are sized here before they are sent.
    func tokenCount(for text: String) async throws -> Int {
        do {
            return try await SystemLanguageModel.default.tokenCount(for: text)
        } catch {
            throw TranscriptIntelligenceFailure.failure(mapping: error)
        }
    }

    func showLimitIncreaseSuggestion() {
        model.quotaUsage.limitIncreaseSuggestion?.show()
    }

    func makeSession(instructions: String, tools: [any Tool]) -> any TranscriptIntelligenceSession {
        PrivateCloudComputeTranscriptIntelligenceSession(
            session: LanguageModelSession(model: model, tools: tools, instructions: instructions)
        )
    }
}
