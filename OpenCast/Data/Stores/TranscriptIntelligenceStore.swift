import Foundation
import FoundationModels
import Observation
import SwiftData

/// Owns the Private Cloud Compute plumbing for Recap and Ask: eligibility,
/// quota, the one-time disclosure, and the last request outcome. Entry
/// points read `isVisible`; request paths run through `perform` so every
/// outcome feeds back into `availability`.
@Observable
final class TranscriptIntelligenceStore {
    private(set) var availability = TranscriptIntelligenceAvailability.modelNotReady
    private(set) var quota = TranscriptIntelligenceQuotaSnapshot()
    /// Lives in `LocalPreferenceRecord` with the rest of the wipeable local
    /// state, like the Chapters & Summary disclosure: a data nuke deletes the
    /// row and the reload makes the next request disclose again.
    private(set) var hasAcknowledgedDisclosure = false
    private(set) var lastFailure: TranscriptIntelligenceFailure?
    @ObservationIgnored private let client: any TranscriptIntelligenceModelClient
    @ObservationIgnored private let isFeatureEnabled: Bool
    @ObservationIgnored private let isAskEnabled: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastFailureDate: Date?

    static let disclosureAcknowledgedPreferenceKey = "transcriptIntelligence.disclosureAcknowledged"
    private static let acknowledgedPreferenceValue = "true"

    init(
        client: (any TranscriptIntelligenceModelClient)? = nil,
        isFeatureEnabled: Bool = TranscriptIntelligenceFeatureFlags.isEnabledForProcess,
        isAskEnabled: Bool = TranscriptIntelligenceFeatureFlags.isAskEnabledForProcess,
        now: @escaping () -> Date = { .now }
    ) {
        self.client = client ?? PrivateCloudComputeTranscriptIntelligenceClient()
        self.isFeatureEnabled = isFeatureEnabled
        self.isAskEnabled = isAskEnabled
        self.now = now
    }

    /// Hidden, not disabled, wherever the feature can never work here: the
    /// flag off, ineligible hardware, or a build without the entitlement.
    var isVisible: Bool {
        isFeatureEnabled && availability != .unsupportedDevice && availability != .notEntitled
    }

    /// Ask ships behind its own compile-time sub-flag until its stage closes.
    var isAskVisible: Bool {
        isVisible && isAskEnabled
    }

    func load(modelContext: ModelContext) {
        // A failed read only means the next request discloses again.
        hasAcknowledgedDisclosure = (try? Self.isDisclosureAcknowledged(modelContext: modelContext)) ?? false
        refreshAvailability()
    }

    /// Called when the scene becomes active and after every request. Drops
    /// transient failures so the next attempt is allowed; entitlement and
    /// rate-limit failures clear on their own terms.
    func refreshAvailability() {
        if let lastFailure, lastFailure.isTransient {
            clearFailure()
        }
        resolveAvailability()
    }

    func acknowledgeDisclosure(modelContext: ModelContext) {
        hasAcknowledgedDisclosure = true
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.disclosureAcknowledgedPreferenceKey,
                value: Self.acknowledgedPreferenceValue,
                modelContext: modelContext
            )
            try modelContext.save()
        } catch {
            // The acknowledgement the user just gave stands for this
            // session; a failed persist only re-shows the disclosure on a
            // later launch.
        }
    }

    var modelIdentifier: String {
        client.modelIdentifier
    }

    func tokenCount(for text: String) async throws -> Int {
        try await client.tokenCount(for: text)
    }

    func showQuotaLimitIncreaseSuggestion() {
        client.showLimitIncreaseSuggestion()
    }

    func makeSession(instructions: String, tools: [any Tool]) -> any TranscriptIntelligenceSession {
        client.makeSession(instructions: instructions, tools: tools)
    }

    /// Runs one request under a wall-clock deadline and folds its outcome
    /// into the store. Cancellation is normal and leaves no trace.
    func perform<Result: Sendable>(
        deadline: Duration = TranscriptIntelligenceRequestDeadline.default,
        _ request: @escaping () async throws -> Result
    ) async throws -> Result {
        do {
            let result = try await TranscriptIntelligenceRequestDeadline.run(deadline, request)
            clearFailure()
            resolveAvailability()
            return result
        } catch {
            let failure = TranscriptIntelligenceFailure.failure(mapping: error)
            record(failure)
            throw failure
        }
    }

    private func record(_ failure: TranscriptIntelligenceFailure) {
        guard failure != .cancelled else {
            return
        }
        lastFailure = failure
        lastFailureDate = now()
        resolveAvailability()
    }

    private func clearFailure() {
        lastFailure = nil
        lastFailureDate = nil
    }

    private func resolveAvailability() {
        quota = client.quota
        availability = TranscriptIntelligenceAvailability.resolve(
            model: client.modelAvailability,
            quota: quota,
            lastFailure: lastFailure,
            failedAt: lastFailureDate,
            now: now()
        )
    }

    private static func isDisclosureAcknowledged(modelContext: ModelContext) throws -> Bool {
        try LocalPreferenceRecord.preference(
            forKey: disclosureAcknowledgedPreferenceKey,
            modelContext: modelContext
        )?.value == acknowledgedPreferenceValue
    }
}
