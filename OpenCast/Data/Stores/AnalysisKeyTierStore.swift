import Foundation
import Observation
import OpenCastAnalysisProviders
import SwiftData

/// What Google last answered about the saved Google key, kept on this device
/// in one `LocalPreferenceRecord`. It holds no key digest and never decides a
/// route: a key can change through iCloud Keychain without the app seeing it,
/// so this only decides whether to ask Google again, and the answer given in
/// a run decides that run. Written only from a tier check's answer or a
/// free-tier send, and only for the key the answer was given for.
@Observable
final class AnalysisKeyTierStore {
    enum State: Equatable, Sendable {
        case unknown
        /// `day` is when Google said so.
        case freeTier(day: Date)
        case notFreeTier
    }

    /// What Google answered, the digest of the key it answered for, and when:
    /// an answer can wait for Save, and the mark names the day Google said so.
    struct Answer: Equatable, Sendable {
        var result: AnalysisTierCheckResult
        var keyDigest: Data
        var answeredAt: Date
    }

    static let preferenceKey = "aiServices.keyTier.google"
    private static let notFreeTierValue = "not_free_tier"
    private static let freeTierPrefix = "free_tier:"

    private(set) var state = State.unknown

    @ObservationIgnored private let save: (ModelContext) throws -> Void
    @ObservationIgnored private let now: () -> Date

    /// `save` and `now` are the test seams for the preference save and the
    /// day Google answered.
    init(
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        now: @escaping () -> Date = { Date.now }
    ) {
        self.save = save
        self.now = now
    }

    func load(modelContext: ModelContext) {
        let record = try? LocalPreferenceRecord.preference(
            forKey: Self.preferenceKey,
            modelContext: ModelContext(modelContext.container)
        )
        state = Self.state(from: record?.value)
    }

    /// `day` is when Google said so; `nil` reads as now. A caller that waited
    /// between the answer and this write passes the answer's own time.
    func noteFreeTier(day: Date? = nil, modelContext: ModelContext) {
        write(.freeTier(day: day ?? now()), modelContext: modelContext)
    }

    func noteNotFreeTier(modelContext: ModelContext) {
        write(.notFreeTier, modelContext: modelContext)
    }

    func reset(modelContext: ModelContext) {
        write(.unknown, modelContext: modelContext)
    }

    /// Writes `answer` only for the key it was given for. `savedKeyDigest` is
    /// read from the Keychain as the answer arrives: a key can change there
    /// during the wait with nothing in the sheet to notice. `nil`, a key gone
    /// or unreadable, matches nothing, and an inconclusive answer writes
    /// nothing.
    func apply(_ answer: Answer, savedKeyDigest: Data?, modelContext: ModelContext) {
        guard answer.keyDigest == savedKeyDigest else {
            return
        }
        switch answer.result {
        case .freeTier: noteFreeTier(day: answer.answeredAt, modelContext: modelContext)
        case .notFreeTier: noteNotFreeTier(modelContext: modelContext)
        case .inconclusive: break
        }
    }

    private func write(_ newState: State, modelContext: ModelContext) {
        state = newState
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(key: Self.preferenceKey, value: Self.value(of: newState), modelContext: context)
            try save(context)
        } catch {
            // The answer stands for this session. A lost write costs one
            // check or one failed attempt on a later launch, never a route.
        }
    }

    private static func value(of state: State) -> String {
        switch state {
        case .unknown: ""
        case .freeTier(let day): freeTierPrefix + day.ISO8601Format()
        case .notFreeTier: notFreeTierValue
        }
    }

    private static func state(from value: String?) -> State {
        guard let value else { return .unknown }
        if value == notFreeTierValue { return .notFreeTier }
        guard value.hasPrefix(freeTierPrefix),
              let day = try? Date(String(value.dropFirst(freeTierPrefix.count)), strategy: .iso8601)
        else {
            return .unknown
        }
        return .freeTier(day: day)
    }
}
