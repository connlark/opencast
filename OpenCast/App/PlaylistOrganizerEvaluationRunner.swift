#if DEBUG
import Foundation
import OSLog
import UIKit

/// Make a Playlist evaluation on a PCC-eligible device or simulator. Reads
/// the cases, settings and episode fixtures pushed into
/// `Documents/PlaylistOrganizerEvaluationInputs`, runs every case through
/// `PlaylistOrganizerClient` with the candidates, line format, line numbers
/// and answer style the case forces (fixture episodes, never the device
/// library, so returned indices line up with the labels), and rewrites
/// `Documents/PlaylistOrganizerEvaluation/report.json` after every run so a
/// partial run is still harvestable; the external evaluation harness scores
/// it. The report carries episode titles, so they stay in the container and
/// never reach the log.
enum PlaylistOrganizerEvaluationRunner {
    nonisolated static let requestArgument = "--opencast-run-playlist-organizer-evaluation"
    nonisolated static let requestEnvironmentKey = "OPENCAST_RUN_PLAYLIST_ORGANIZER_EVALUATION"

    static let inputDirectory = URL.documentsDirectory
        .appending(path: "PlaylistOrganizerEvaluationInputs", directoryHint: .isDirectory)
    static let outputDirectory = URL.documentsDirectory
        .appending(path: "PlaylistOrganizerEvaluation", directoryHint: .isDirectory)
    static var reportURL: URL {
        outputDirectory.appending(path: "report.json")
    }

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "PlaylistOrganizerEvaluation")
    private static var hasStarted = false

    nonisolated static var isRequested: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(requestArgument)
            || processInfo.environment[requestEnvironmentKey] == "1"
    }

    static func runIfRequested() async {
        guard isRequested, !hasStarted else {
            return
        }
        hasStarted = true
        await run()
    }

    private static func run() async {
        // A long run must not lock the screen: a suspended app makes every
        // in-flight PCC turn look like a timeout.
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled
        }
        var report = Report(
            promptVersion: PlaylistOrganizerPrompt.promptVersion,
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            startedAt: .now
        )
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let cases = try decode([EvaluationCase].self, from: inputDirectory.appending(path: "cases.json"))
            let plans = try cases.map(CasePlan.init)
            report.repeats = try loadRepeats()
            var fixtures: [String: LoadedFixture] = [:]
            for plan in plans where fixtures[plan.fixture] == nil {
                fixtures[plan.fixture] = try loadFixture(slug: plan.fixture)
            }
            let store = TranscriptIntelligenceStore(isFeatureEnabled: true)
            store.refreshAvailability()
            report.availability = String(describing: store.availability)
            report.modelIdentifier = store.modelIdentifier
            let client = PlaylistOrganizerClient(store: store)
            save(report)
            logger.log(
                "evaluation started cases=\(plans.count, privacy: .public) repeats=\(report.repeats, privacy: .public) availability=\(report.availability ?? "", privacy: .public)"
            )

            for plan in plans {
                guard let fixture = fixtures[plan.fixture] else {
                    throw InputError.missingFixture(plan.fixture)
                }
                report.cases.append(CaseReport(plan))
                let caseIndex = report.cases.count - 1
                for repeatIndex in 0..<report.repeats {
                    try Task.checkCancellation()
                    let run = await client.run(
                        plan.request(podcastID: fixture.podcastID, showTitle: fixture.title),
                        episodes: fixture.episodes,
                        snapshotsByEpisodeID: fixture.snapshotsByEpisodeID,
                        options: plan.options
                    )
                    let runReport = RunReport(run, index: repeatIndex, plan: plan, fixture: fixture)
                    report.cases[caseIndex].runs.append(runReport)
                    save(report)
                    logger.log(
                        "case \(plan.id, privacy: .public) run \(repeatIndex, privacy: .public) outcome=\(runReport.outcome, privacy: .public) attempts=\(run.attempts, privacy: .public)"
                    )
                }
            }
            report.status = "completed"
        } catch is CancellationError {
            report.status = "failed"
            report.error = "Cancelled before every run finished."
        } catch {
            report.status = "failed"
            report.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            logger.error("evaluation setup failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        report.finishedAt = .now
        save(report)
        logger.log("evaluation finished status=\(report.status, privacy: .public)")
    }

    private static func loadRepeats() throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: inputDirectory.appending(path: "settings.json"))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return 1
        }
        let repeats = try decoder().decode(Settings.self, from: data).repeats ?? 1
        guard repeats >= 1 else {
            throw InputError.invalidRepeats(repeats)
        }
        return repeats
    }

    /// Builder episodes and the snapshots validation resolves them against,
    /// both keyed by a synthetic episode id that maps back to the fixture index.
    private static func loadFixture(slug: String) throws -> LoadedFixture {
        let fixture = try decode(Fixture.self, from: inputDirectory.appending(path: "fixtures/\(slug).json"))
        let podcastID = "evaluation-\(slug)"
        let dateParser = ISO8601DateFormatter()
        let fractionalDateParser = ISO8601DateFormatter()
        fractionalDateParser.formatOptions.insert(.withFractionalSeconds)
        let cachedAt = Date.now
        var loaded = LoadedFixture(podcastID: podcastID, title: fixture.title)
        for (position, episode) in fixture.episodes.enumerated() {
            guard episode.index == position else {
                throw InputError.episodeOrder(slug)
            }
            var publishedAt: Date?
            if let published = episode.published {
                guard let date = dateParser.date(from: published) ?? fractionalDateParser.date(from: published) else {
                    throw InputError.unreadableDate(slug: slug, index: position)
                }
                publishedAt = date
            }
            let episodeID = "\(podcastID)-\(episode.index)"
            let snippet = episode.snippet?.isEmpty == false ? episode.snippet : nil
            loaded.episodes.append(
                PlaylistOrganizerEpisode(
                    index: episode.index,
                    episodeID: episodeID,
                    publishedAt: publishedAt,
                    duration: episode.durationSeconds,
                    title: episode.title,
                    snippet: snippet
                )
            )
            loaded.snapshotsByEpisodeID[episodeID] = EpisodeListItemSnapshot(
                episodeID: episodeID,
                podcastID: podcastID,
                podcastTitle: fixture.title,
                title: episode.title,
                summary: nil,
                publishedAt: publishedAt,
                duration: episode.durationSeconds,
                audioURL: nil,
                artworkURL: nil,
                artworkPreview: nil,
                guid: nil,
                cachedAt: cachedAt
            )
            loaded.indexByEpisodeID[episodeID] = episode.index
        }
        return loaded
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try decoder().decode(type, from: Data(contentsOf: url))
    }

    private static func save(_ report: Report) {
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            encoder.nonConformingFloatEncodingStrategy = nonConformingFloats
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            logger.error("report write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let nonConformingFloats = JSONEncoder.NonConformingFloatEncodingStrategy.convertToString(
        positiveInfinity: "Infinity",
        negativeInfinity: "-Infinity",
        nan: "NaN"
    )

    /// The model's answer re-encoded in the instructions' JSON shape, with
    /// every number mapped back to the episode index it stands for, so the
    /// harness scores it exactly as it scored answers taken from the model
    /// directly.
    private static func rawJSON(_ proposals: [PlaylistProposal], input: PlaylistOrganizerInput?) -> String? {
        let set = RawProposalSet(playlists: proposals.map { RawProposal($0, input: input) })
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = nonConformingFloats
        encoder.outputFormatting = .sortedKeys
        do {
            let data = try encoder.encode(set)
            return String(decoding: data, as: UTF8.self)
        } catch {
            logger.error("raw answer encode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func name(of outcome: PlaylistOrganizerOutcome) -> String {
        switch outcome {
        case .proposals: "proposals"
        case .empty: "empty"
        case .declined: "declined"
        case .limitReached: "limitReached"
        case .offline: "offline"
        case .serviceUnavailable: "serviceUnavailable"
        case .timedOut: "timedOut"
        case .malformed: "malformed"
        case .tooLong: "tooLong"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    /// The model answered and its answer decoded.
    private static func isAnswer(_ outcome: PlaylistOrganizerOutcome) -> Bool {
        switch outcome {
        case .proposals, .empty:
            true
        case .declined, .limitReached, .offline, .serviceUnavailable, .timedOut, .malformed, .tooLong,
             .cancelled, .failed:
            false
        }
    }

    private static func guardrailSide(of failure: TranscriptIntelligenceFailure) -> String? {
        if case .guardrailViolation(let side) = failure {
            side.rawValue
        } else {
            nil
        }
    }

    private static func kind(of failure: TranscriptIntelligenceFailure) -> String {
        switch failure {
        case .cancelled: "cancelled"
        case .guardrailViolation: "guardrailViolation"
        case .refusal: "refusal"
        case .rateLimited: "rateLimited"
        case .quotaLimitReached: "quotaLimitReached"
        case .contextSizeExceeded: "contextSizeExceeded"
        case .notEntitled: "notEntitled"
        case .offline: "offline"
        case .serviceUnavailable: "serviceUnavailable"
        case .timeout: "timeout"
        case .unsupportedLanguage: "unsupportedLanguage"
        case .malformedOutput: "malformedOutput"
        case .unknown: "unknown"
        }
    }

    private enum InputError: LocalizedError {
        case unknownMode(String)
        case unknownVariant(String)
        case unknownLines(String)
        case unknownAnswerStyle(String)
        case unknownLineNumbers(String)
        case missingPrefilter(String)
        case invalidRepeats(Int)
        case missingFixture(String)
        case episodeOrder(String)
        case unreadableDate(slug: String, index: Int)

        var errorDescription: String? {
            switch self {
            case .unknownMode(let caseID): "Case \(caseID) has an unknown mode."
            case .unknownVariant(let caseID): "Case \(caseID) has an unknown variant."
            case .unknownLines(let caseID): "Case \(caseID) has an unknown lines value."
            case .unknownAnswerStyle(let caseID): "Case \(caseID) has an unknown answer style."
            case .unknownLineNumbers(let caseID): "Case \(caseID) has an unknown line numbers value."
            case .missingPrefilter(let caseID): "Prefiltered case \(caseID) has neither prefilter indices nor a prefilter query."
            case .invalidRepeats(let repeats): "Settings ask for \(repeats) repeats; at least 1 is needed."
            case .missingFixture(let slug): "No fixture was loaded for \(slug)."
            case .episodeOrder(let slug): "Fixture \(slug) episode indices must run 0, 1, 2… in order."
            case .unreadableDate(let slug, let index): "Fixture \(slug) episode \(index) has an unreadable published date."
            }
        }
    }

    // MARK: - Inputs

    private struct Settings: Decodable {
        var repeats: Int?
    }

    private struct EvaluationCase: Decodable {
        var id: String
        var fixture: String
        var mode: String
        var request: String?
        var variant: String?
        var prefilter: Prefilter?
        var prefilterIndices: [Int]?
        var limitNewest: Int?
        var lines: String?
        /// standard (default) or indicesOnly.
        var answerStyle: String?
        /// index (default, as the sheet sends) or gapped.
        var lineNumbers: String?
    }

    private struct Prefilter: Decodable {
        var query: String
        var k: Int
    }

    private struct Fixture: Decodable {
        var title: String
        var episodes: [FixtureEpisode]
    }

    private struct FixtureEpisode: Decodable {
        var index: Int
        var published: String?
        var durationSeconds: TimeInterval?
        var title: String
        var snippet: String?
    }

    private struct LoadedFixture {
        var podcastID: String
        var title: String
        var episodes: [PlaylistOrganizerEpisode] = []
        var snapshotsByEpisodeID: [String: EpisodeListItemSnapshot] = [:]
        var indexByEpisodeID: [String: Int] = [:]
    }

    /// One case resolved into the client's request options, checked before any
    /// model turn so a bad case fails the run at once.
    private struct CasePlan {
        var id: String
        var fixture: String
        var mode: PlaylistOrganizerMode
        var requestText: String?
        var variant: String?
        var linesRequested: String
        var candidatesName: String
        var answerStyle: PlaylistOrganizerAnswerStyle
        var lineNumbers: String
        var options = PlaylistOrganizerInputOptions()

        init(_ evaluationCase: EvaluationCase) throws {
            id = evaluationCase.id
            fixture = evaluationCase.fixture
            requestText = evaluationCase.request
            variant = evaluationCase.variant
            linesRequested = evaluationCase.lines ?? "auto"
            guard let mode = PlaylistOrganizerMode(rawValue: evaluationCase.mode) else {
                throw InputError.unknownMode(evaluationCase.id)
            }
            self.mode = mode

            guard let answerStyle = PlaylistOrganizerAnswerStyle(
                rawValue: evaluationCase.answerStyle ?? PlaylistOrganizerAnswerStyle.standard.rawValue
            ) else {
                throw InputError.unknownAnswerStyle(evaluationCase.id)
            }
            self.answerStyle = answerStyle
            lineNumbers = evaluationCase.lineNumbers ?? "index"
            guard ["gapped", "index"].contains(lineNumbers) else {
                throw InputError.unknownLineNumbers(evaluationCase.id)
            }
            options.lineNumbers = lineNumbers == "index" ? .index : .gapped(seed: nil)

            if linesRequested != "auto" {
                guard let rung = PlaylistOrganizerInput.Rung(rawValue: linesRequested) else {
                    throw InputError.unknownLines(evaluationCase.id)
                }
                options.rungs = [rung]
            }

            guard [nil, "production", "full", "prefiltered"].contains(evaluationCase.variant) else {
                throw InputError.unknownVariant(evaluationCase.id)
            }
            if let indices = evaluationCase.prefilterIndices {
                options.candidates = .explicit(indices)
                candidatesName = "explicit"
            } else if evaluationCase.variant == "prefiltered" {
                guard let prefilter = evaluationCase.prefilter else {
                    throw InputError.missingPrefilter(evaluationCase.id)
                }
                options.candidates = .lexical(query: prefilter.query, limit: prefilter.k)
                candidatesName = "lexical"
            } else if let limit = evaluationCase.limitNewest {
                options.candidates = .newest(limit)
                candidatesName = "newest"
            } else if evaluationCase.variant == "full" {
                options.candidates = .full
                candidatesName = "full"
            } else {
                candidatesName = "automatic"
            }
        }

        func request(podcastID: String, showTitle: String) -> PlaylistOrganizerRequest {
            PlaylistOrganizerRequest(
                podcastID: podcastID,
                showTitle: showTitle,
                mode: mode,
                prompt: mode == .prompted ? requestText : nil,
                answerStyle: answerStyle
            )
        }
    }

    // MARK: - Report

    // Optional fields encode as explicit nulls so every record has the same keys.

    private struct Report: Encodable {
        var status = "running"
        var promptVersion: String
        var modelIdentifier: String?
        var availability: String?
        var deviceModel: String
        var systemVersion: String
        var startedAt: Date
        var finishedAt: Date?
        var repeats = 1
        var error: String?
        var cases: [CaseReport] = []

        private enum CodingKeys: String, CodingKey {
            case status, promptVersion, modelIdentifier, availability, deviceModel, systemVersion
            case startedAt, finishedAt, repeats, error, cases
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(status, forKey: .status)
            try container.encode(promptVersion, forKey: .promptVersion)
            try container.encode(modelIdentifier, forKey: .modelIdentifier)
            try container.encode(availability, forKey: .availability)
            try container.encode(deviceModel, forKey: .deviceModel)
            try container.encode(systemVersion, forKey: .systemVersion)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(finishedAt, forKey: .finishedAt)
            try container.encode(repeats, forKey: .repeats)
            try container.encode(error, forKey: .error)
            try container.encode(cases, forKey: .cases)
        }
    }

    private struct CaseReport: Encodable {
        var id: String
        var fixture: String
        var mode: String
        var request: String?
        var variant: String?
        var linesRequested: String
        var candidates: String
        var answerStyle: String
        var lineNumbers: String
        var runs: [RunReport] = []

        private enum CodingKeys: String, CodingKey {
            case id, fixture, mode, request, variant, linesRequested, candidates, answerStyle, lineNumbers, runs
        }

        init(_ plan: CasePlan) {
            id = plan.id
            fixture = plan.fixture
            mode = plan.mode.rawValue
            request = plan.requestText
            variant = plan.variant
            linesRequested = plan.linesRequested
            candidates = plan.candidatesName
            answerStyle = plan.answerStyle.rawValue
            lineNumbers = plan.lineNumbers
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(fixture, forKey: .fixture)
            try container.encode(mode, forKey: .mode)
            try container.encode(request, forKey: .request)
            try container.encode(variant, forKey: .variant)
            try container.encode(linesRequested, forKey: .linesRequested)
            try container.encode(candidates, forKey: .candidates)
            try container.encode(answerStyle, forKey: .answerStyle)
            try container.encode(lineNumbers, forKey: .lineNumbers)
            try container.encode(runs, forKey: .runs)
        }
    }

    private struct RunReport: Encodable {
        var index: Int
        var ok: Bool
        var outcome: String
        var elapsedSeconds: Double
        var attempts: Int
        /// Case names of the failures retried before the outcome.
        var retried: [String]
        /// The side of every guardrail decline in the run, retried or final.
        var guardrailSides: [String]
        var usage: UsageReport?
        var error: ErrorReport?
        var rawJSON: String?
        var sent: SentReport?
        var playlists: [PlaylistReport]

        private enum CodingKeys: String, CodingKey {
            case index, ok, outcome
            case elapsedSeconds = "elapsedS"
            case attempts, retried, guardrailSides, usage, error
            case rawJSON = "rawJson"
            case sent, playlists
        }

        init(_ run: PlaylistOrganizerRun, index: Int, plan: CasePlan, fixture: LoadedFixture) {
            self.index = index
            outcome = PlaylistOrganizerEvaluationRunner.name(of: run.outcome)
            ok = PlaylistOrganizerEvaluationRunner.isAnswer(run.outcome)
            elapsedSeconds = run.elapsed / .seconds(1)
            attempts = run.attempts
            retried = run.retriedFailures.map(PlaylistOrganizerEvaluationRunner.kind(of:))
            guardrailSides = (run.retriedFailures + [run.failure].compactMap(\.self))
                .compactMap(PlaylistOrganizerEvaluationRunner.guardrailSide(of:))
            usage = run.usage.map(UsageReport.init)
            error = ok ? nil : ErrorReport(run, outcome: outcome, mode: plan.mode, answerStyle: plan.answerStyle)
            rawJSON = ok || !run.rawProposals.isEmpty
                ? PlaylistOrganizerEvaluationRunner.rawJSON(run.rawProposals, input: run.input)
                : nil
            sent = run.input.map { SentReport($0, budget: plan.options.budget, lineNumbers: plan.lineNumbers) }
            if case .proposals(let drafts, _) = run.outcome {
                playlists = drafts.map { PlaylistReport($0, indexByEpisodeID: fixture.indexByEpisodeID) }
            } else {
                playlists = []
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(ok, forKey: .ok)
            try container.encode(outcome, forKey: .outcome)
            try container.encode(elapsedSeconds, forKey: .elapsedSeconds)
            try container.encode(attempts, forKey: .attempts)
            try container.encode(retried, forKey: .retried)
            try container.encode(guardrailSides, forKey: .guardrailSides)
            try container.encode(usage, forKey: .usage)
            try container.encode(error, forKey: .error)
            try container.encode(rawJSON, forKey: .rawJSON)
            try container.encode(sent, forKey: .sent)
            try container.encode(playlists, forKey: .playlists)
        }
    }

    private struct UsageReport: Encodable {
        var inputTokens: Int
        var outputTokens: Int

        init(_ usage: TranscriptIntelligenceUsage) {
            inputTokens = usage.inputTokens
            outputTokens = usage.outputTokens
        }
    }

    private struct ErrorReport: Encodable {
        /// The failure's case name without associated values, or the outcome's
        /// name when no model failure caused it.
        var kind: String
        var message: String
        /// input, output, recitation or unknown for a guardrail decline.
        var side: String?

        private enum CodingKeys: String, CodingKey {
            case kind, message, side
        }

        init(
            _ run: PlaylistOrganizerRun,
            outcome: String,
            mode: PlaylistOrganizerMode,
            answerStyle: PlaylistOrganizerAnswerStyle
        ) {
            if let failure = run.failure {
                kind = PlaylistOrganizerEvaluationRunner.kind(of: failure)
                message = String(describing: failure)
                side = PlaylistOrganizerEvaluationRunner.guardrailSide(of: failure)
            } else {
                kind = outcome
                message = run.outcome.message(for: mode, answerStyle: answerStyle) ?? outcome
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(message, forKey: .message)
            try container.encode(side, forKey: .side)
        }
    }

    private struct SentReport: Encodable {
        var lines: String
        /// index or gapped.
        var lineNumbers: String
        var scope: String
        var episodeCount: Int
        var sentCount: Int
        var indices: [Int]
        var rankedIndices: [Int]?
        var framedTokens: Int
        /// The budget the case asked for; a context step-down may have halved
        /// it for the input actually sent.
        var budget: Int
        var lexicalCount: Int?
        var fillCount: Int?
        var retrievalMilliseconds: Double
        /// Exactly what the model received, so a decline can be replayed on
        /// the Mac probe. Episode text stays in the container.
        var instructions: String
        var prompt: String

        private enum CodingKeys: String, CodingKey {
            case lines, lineNumbers, scope, episodeCount, sentCount, indices, rankedIndices, framedTokens, budget
            case lexicalCount, fillCount
            case retrievalMilliseconds = "retrievalMs"
            case instructions, prompt
        }

        init(_ input: PlaylistOrganizerInput, budget: Int, lineNumbers: String) {
            lines = input.rung.rawValue
            self.lineNumbers = lineNumbers
            scope = input.scope.promptText
            episodeCount = input.scope.totalCount
            sentCount = input.candidateIndices.count
            indices = input.candidateIndices
            rankedIndices = input.window?.rankedPositions
            framedTokens = input.framedTokenCount
            self.budget = budget
            lexicalCount = input.window?.lexicalCount
            fillCount = input.window?.fillCount
            retrievalMilliseconds = input.retrievalMilliseconds
            instructions = input.instructions
            prompt = input.prompt
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lines, forKey: .lines)
            try container.encode(lineNumbers, forKey: .lineNumbers)
            try container.encode(scope, forKey: .scope)
            try container.encode(episodeCount, forKey: .episodeCount)
            try container.encode(sentCount, forKey: .sentCount)
            try container.encode(indices, forKey: .indices)
            try container.encode(rankedIndices, forKey: .rankedIndices)
            try container.encode(framedTokens, forKey: .framedTokens)
            try container.encode(budget, forKey: .budget)
            try container.encode(lexicalCount, forKey: .lexicalCount)
            try container.encode(fillCount, forKey: .fillCount)
            try container.encode(retrievalMilliseconds, forKey: .retrievalMilliseconds)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(prompt, forKey: .prompt)
        }
    }

    private struct PlaylistReport: Encodable {
        var title: String
        var rationale: String
        var episodeIndices: [Int]
        var episodeTitles: [String]

        init(_ draft: PlaylistProposalDraft, indexByEpisodeID: [String: Int]) {
            title = draft.title
            rationale = draft.rationale
            episodeIndices = draft.episodes.compactMap { indexByEpisodeID[$0.episodeID] }
            episodeTitles = draft.episodes.map(\.title)
        }
    }

    private struct RawProposalSet: Encodable {
        var playlists: [RawProposal]
    }

    private struct RawProposal: Encodable {
        var title: String
        var rationale: String
        var episodeIndices: [Int]
        var confidence: Double

        /// Index numbers pass through. A gapped number missing from the
        /// input's table becomes negative, so the harness counts it invalid.
        init(_ proposal: PlaylistProposal, input: PlaylistOrganizerInput?) {
            title = proposal.title
            rationale = proposal.rationale
            episodeIndices = proposal.episodeIndices.map { number in
                guard let input else {
                    return number
                }
                if let index = input.episodeIndex(forLineNumber: number) {
                    return index
                }
                return number < 0 ? number : -1 - number
            }
            confidence = proposal.confidence
        }
    }
}
#endif
