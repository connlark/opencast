import Foundation
import FoundationModels

/// One Make a Playlist request end to end: the token-budgeted episode list,
/// a fresh structured PCC turn per attempt under the store's deadline, and
/// validation of the returned indices against the list that was sent.
final class PlaylistOrganizerClient {
    nonisolated static let maximumResponseTokens = 2_048
    nonisolated static let maximumProposals = 12
    nonisolated static let minimumUnpromptedEpisodeCount = 3
    nonisolated static let maximumContextStepDowns = 2

    private let store: TranscriptIntelligenceStore
    private let deadline: Duration

    init(store: TranscriptIntelligenceStore, deadline: Duration = TranscriptIntelligenceRequestDeadline.default) {
        self.store = store
        self.deadline = deadline
    }

    /// The sheet's call.
    func organize(
        _ request: PlaylistOrganizerRequest,
        episodes: [PlaylistOrganizerEpisode],
        snapshotsByEpisodeID: [String: EpisodeListItemSnapshot]
    ) async -> PlaylistOrganizerOutcome {
        await run(request, episodes: episodes, snapshotsByEpisodeID: snapshotsByEpisodeID).outcome
    }

    /// The same request with its measurements; the evaluation runner forces `options`.
    ///
    /// A decline and an unreadable answer each get one silent retry with the
    /// same input, because both are stochastic on PCC. A full context steps
    /// down to a leaner line format (then a smaller budget) and rebuilds.
    /// Nothing about the request, the show or its episodes is logged.
    func run(
        _ request: PlaylistOrganizerRequest,
        episodes: [PlaylistOrganizerEpisode],
        snapshotsByEpisodeID: [String: EpisodeListItemSnapshot],
        options: PlaylistOrganizerInputOptions = PlaylistOrganizerInputOptions()
    ) async -> PlaylistOrganizerRun {
        let clock = ContinuousClock()
        let started = clock.now
        var result = await runTurns(
            Self.normalized(request),
            episodes: episodes,
            snapshotsByEpisodeID: snapshotsByEpisodeID,
            options: options
        )
        result.elapsed = started.duration(to: clock.now)
        return result
    }

    /// How much of the show a request in `mode` looks through (the form's
    /// footnote): the whole list for a typed request, which retrieval may
    /// then narrow, and the capped list for suggestions. nil when counting fails.
    func formScope(
        showTitle: String,
        episodes: [PlaylistOrganizerEpisode],
        mode: PlaylistOrganizerMode
    ) async -> PlaylistOrganizerScope? {
        let request = Self.normalized(
            PlaylistOrganizerRequest(podcastID: "", showTitle: showTitle, mode: .unprompted, prompt: nil)
        )
        var options = PlaylistOrganizerInputOptions()
        if mode == .prompted {
            options.candidates = .full
        }
        do {
            return try await PlaylistOrganizerInputBuilder.build(
                request: request,
                episodes: episodes,
                options: options,
                tokenCount: tokenCounter()
            ).scope
        } catch {
            return nil
        }
    }

    /// Keeps indices that were sent and still resolve to a library episode,
    /// in the model's order (the prompt asks for chronological order unless
    /// the request implies another); drops repeats, and proposals too small
    /// to be worth saving.
    nonisolated static func validate(
        _ set: PlaylistProposalSet,
        input: PlaylistOrganizerInput,
        mode: PlaylistOrganizerMode,
        snapshotsByEpisodeID: [String: EpisodeListItemSnapshot]
    ) -> [PlaylistProposalDraft] {
        let minimumEpisodeCount = mode == .prompted ? 1 : minimumUnpromptedEpisodeCount
        var drafts: [PlaylistProposalDraft] = []
        for proposal in set.playlists {
            guard drafts.count < maximumProposals else {
                break
            }
            var seenIndices = Set<Int>()
            var seenEpisodeIDs = Set<String>()
            var episodes: [EpisodeListItemSnapshot] = []
            for index in proposal.episodeIndices {
                guard seenIndices.insert(index).inserted,
                      let episode = input.episodesByIndex[index],
                      let snapshot = snapshotsByEpisodeID[episode.episodeID],
                      seenEpisodeIDs.insert(snapshot.episodeID).inserted
                else {
                    continue
                }
                episodes.append(snapshot)
            }
            guard episodes.count >= minimumEpisodeCount else {
                continue
            }
            drafts.append(PlaylistProposalDraft(
                id: UUID(),
                title: collapsingWhitespace(proposal.title),
                rationale: collapsingWhitespace(proposal.rationale),
                episodes: episodes
            ))
        }
        return drafts
    }

    private func runTurns(
        _ request: PlaylistOrganizerRequest,
        episodes: [PlaylistOrganizerEpisode],
        snapshotsByEpisodeID: [String: EpisodeListItemSnapshot],
        options initialOptions: PlaylistOrganizerInputOptions
    ) async -> PlaylistOrganizerRun {
        var result = PlaylistOrganizerRun(
            outcome: .cancelled,
            input: nil,
            elapsed: .zero,
            usage: nil,
            attempts: 0,
            rawProposals: [],
            failure: nil
        )
        guard !episodes.isEmpty else {
            result.outcome = .empty(scope: PlaylistOrganizerScope(kind: .all, sentCount: 0, totalCount: 0))
            return result
        }
        let tokenCount = tokenCounter()
        var options = initialOptions
        var retryInput: PlaylistOrganizerInput?
        // One silent resend of the same input per request, whatever caused
        // it: the privacy copy promises "once more".
        var hasResentInput = false
        var contextStepDowns = 0
        while true {
            var isModelTurn = false
            do {
                try Task.checkCancellation()
                let input: PlaylistOrganizerInput
                if let retryInput {
                    input = retryInput
                } else {
                    input = try await PlaylistOrganizerInputBuilder.build(
                        request: request,
                        episodes: episodes,
                        options: options,
                        tokenCount: tokenCount
                    )
                }
                result.input = input
                // The last token count may have returned after the sheet
                // went away; nothing should leave the device for it.
                try Task.checkCancellation()
                result.attempts += 1
                isModelTurn = true
                let response = try await respond(to: input)
                let drafts = Self.validate(
                    response.content,
                    input: input,
                    mode: request.mode,
                    snapshotsByEpisodeID: snapshotsByEpisodeID
                )
                result.usage = response.usage
                result.rawProposals = response.content.playlists
                result.failure = nil
                result.outcome = drafts.isEmpty ? .empty(scope: input.scope) : .proposals(drafts, scope: input.scope)
                return result
            } catch is CancellationError {
                result.failure = .cancelled
                result.outcome = .cancelled
                return result
            } catch let failure as TranscriptIntelligenceFailure {
                result.failure = failure
                switch failure {
                case .cancelled:
                    result.outcome = .cancelled
                case .guardrailViolation, .refusal:
                    if isModelTurn, !hasResentInput {
                        hasResentInput = true
                        result.retriedFailures.append(failure)
                        retryInput = result.input
                        continue
                    }
                    result.outcome = .declined
                case .rateLimited(let resetDate), .quotaLimitReached(let resetDate):
                    result.outcome = .limitReached(resetDate: resetDate)
                case .contextSizeExceeded:
                    if isModelTurn, contextStepDowns < Self.maximumContextStepDowns, let input = result.input {
                        contextStepDowns += 1
                        result.retriedFailures.append(failure)
                        options = Self.steppedDown(options, below: input.rung)
                        retryInput = nil
                        continue
                    }
                    result.outcome = .tooLong
                case .notEntitled:
                    result.outcome = .failed("Make a Playlist isn’t available in this build.")
                case .offline:
                    result.outcome = .offline
                case .serviceUnavailable:
                    result.outcome = .serviceUnavailable
                case .timeout:
                    result.outcome = .timedOut
                case .unsupportedLanguage:
                    result.outcome = .failed("Apple’s model doesn’t support this show’s language.")
                case .malformedOutput:
                    if isModelTurn, !hasResentInput {
                        hasResentInput = true
                        result.retriedFailures.append(failure)
                        retryInput = result.input
                        continue
                    }
                    result.outcome = .malformed
                case .unknown(let detail):
                    result.outcome = .failed("Apple’s model couldn’t respond: \(detail)")
                }
                return result
            } catch {
                result.failure = .unknown(error.localizedDescription)
                result.outcome = .failed(error.localizedDescription)
                return result
            }
        }
    }

    private func respond(to input: PlaylistOrganizerInput) async throws -> TranscriptIntelligenceResponse<PlaylistProposalSet> {
        let session = store.makeSession(instructions: PlaylistOrganizerPrompt.instructions, tools: [])
        let prompt = input.prompt
        return try await store.perform(deadline: deadline) {
            try await session.respond(
                to: prompt,
                generating: PlaylistProposalSet.self,
                options: TranscriptIntelligenceGenerationOptions(
                    maximumResponseTokens: Self.maximumResponseTokens,
                    toolCalling: .disallowed
                )
            )
        }
    }

    private func tokenCounter() -> @Sendable (String) async throws -> Int {
        { [store] text in try await store.tokenCount(for: text) }
    }

    /// The line formats below the one that overflowed; once none is left,
    /// half the budget, so the builder keeps fewer episodes.
    private static func steppedDown(
        _ options: PlaylistOrganizerInputOptions,
        below rung: PlaylistOrganizerInput.Rung
    ) -> PlaylistOrganizerInputOptions {
        var options = options
        let rungs = options.rungs.isEmpty ? PlaylistOrganizerInput.Rung.allCases : options.rungs
        if let position = rungs.firstIndex(of: rung), position + 1 < rungs.count {
            options.rungs = Array(rungs[(position + 1)...])
        } else {
            options.budget /= 2
        }
        return options
    }

    private static func normalized(_ request: PlaylistOrganizerRequest) -> PlaylistOrganizerRequest {
        var request = request
        request.showTitle = collapsingWhitespace(request.showTitle)
        let prompt = collapsingWhitespace(request.prompt ?? "")
        if request.mode == .prompted, prompt.isEmpty {
            request.mode = .unprompted
        }
        request.prompt = request.mode == .prompted ? prompt : nil
        return request
    }

    private nonisolated static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
