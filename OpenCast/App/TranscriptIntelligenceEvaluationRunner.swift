#if DEBUG
import Foundation
import OSLog
import OpenCastTranscription
import UIKit

/// Recap and Ask evaluation on a PCC-eligible device. Reads the fixture
/// transcripts and cases pushed into
/// `Documents/TranscriptIntelligenceEvaluationInputs`, runs every case
/// through the production code (real PCC, fresh cache; one Ask session per
/// fixture so reseeding happens as it would for a listener), and writes
/// `Documents/TranscriptIntelligenceEvaluation/report.json` after each case
/// so a partial run is still harvestable; the external evaluation harness
/// beside the plan scores it.
enum TranscriptIntelligenceEvaluationRunner {
    nonisolated static let requestArgument = "--opencast-run-transcript-intelligence-evaluation"
    nonisolated static let requestEnvironmentKey = "OPENCAST_RUN_TRANSCRIPT_INTELLIGENCE_EVALUATION"

    static let inputDirectory = URL.documentsDirectory
        .appending(path: "TranscriptIntelligenceEvaluationInputs", directoryHint: .isDirectory)
    static let outputDirectory = URL.documentsDirectory
        .appending(path: "TranscriptIntelligenceEvaluation", directoryHint: .isDirectory)
    static var reportURL: URL {
        outputDirectory.appending(path: "report.json")
    }

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "TranscriptIntelligenceEvaluation")
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
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        var report = Report(
            startedAt: .now,
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            promptVersion: TranscriptIntelligencePrompts.promptVersion,
            askPromptVersion: TranscriptIntelligencePrompts.askPromptVersion,
            tokenBudget: TranscriptRecapWindowBuilder.defaultTokenBudget,
            maximumResponseTokens: TranscriptRecapGenerator.maximumResponseTokens,
            askSessionInputTokenBudget: TranscriptAskSession.sessionInputTokenBudget,
            askMaximumToolCallsPerTurn: TranscriptAskSession.maximumToolCallsPerTurn,
            askToolTokenBudget: TranscriptToolOutput.defaultTokenBudget
        )
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let cases = try decode(Cases.self, from: inputDirectory.appending(path: "cases.json"))
            report.datasetVersion = cases.datasetVersion
            let store = TranscriptIntelligenceStore(isFeatureEnabled: true)
            store.refreshAvailability()
            report.availability = String(describing: store.availability)
            report.modelIdentifier = store.modelIdentifier
            let cacheDirectory = outputDirectory.appending(path: "cache", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: cacheDirectory)
            let generator = TranscriptRecapGenerator(store: store, cache: TranscriptRecapCache(directory: cacheDirectory))
            save(report)
            logger.log("evaluation started cases=\(cases.cases.count, privacy: .public) availability=\(report.availability ?? "", privacy: .public)")

            var documents: [String: EpisodeTranscriptDocument] = [:]
            var askSessions: [String: TranscriptAskSession] = [:]
            for evaluationCase in cases.cases {
                var caseReport = CaseReport(
                    caseID: evaluationCase.caseID,
                    fixture: evaluationCase.fixture,
                    operation: evaluationCase.operation ?? "recap",
                    kind: evaluationCase.kind,
                    playhead: evaluationCase.playhead,
                    question: evaluationCase.question,
                    startedAt: .now
                )
                do {
                    let document = try loadDocument(named: evaluationCase.fixture, into: &documents)
                    if caseReport.operation == "ask" {
                        try await runAskCase(evaluationCase, document: document, store: store, sessions: &askSessions, into: &caseReport)
                    } else {
                        try await runRecapCase(evaluationCase, document: document, generator: generator, into: &caseReport)
                    }
                } catch {
                    caseReport.error = ErrorReport(error)
                }
                caseReport.finishedAt = .now
                caseReport.availabilityAfter = String(describing: store.availability)
                report.cases.append(caseReport)
                save(report)
                logger.log("case \(evaluationCase.caseID, privacy: .public) ok=\(caseReport.ok, privacy: .public)")
            }
            report.status = "completed"
        } catch {
            report.status = "failed"
            report.errorMessage = error.localizedDescription
        }
        report.finishedAt = .now
        save(report)
        logger.log("evaluation finished status=\(report.status, privacy: .public)")
    }

    private static func runRecapCase(
        _ evaluationCase: EvaluationCase,
        document: EpisodeTranscriptDocument,
        generator: TranscriptRecapGenerator,
        into caseReport: inout CaseReport
    ) async throws {
        guard let kind = evaluationCase.kind, let playhead = evaluationCase.playhead else {
            throw InputError.missingRecapWindow(evaluationCase.caseID)
        }
        var attempts: [AttemptReport] = []
        generator.onAttempt = { attempt in
            attempts.append(AttemptReport(attempt, document: document))
        }
        defer {
            generator.onAttempt = nil
            caseReport.attempts = attempts
        }
        let result = try await generator.recap(document: document, kind: kind, playhead: playhead)
        caseReport.result = ResultReport(result, document: document)
        caseReport.ok = true
    }

    /// One Ask session per fixture, so consecutive questions about one
    /// episode share a conversation and the input budget reseeds it as it
    /// would for a listener.
    private static func runAskCase(
        _ evaluationCase: EvaluationCase,
        document: EpisodeTranscriptDocument,
        store: TranscriptIntelligenceStore,
        sessions: inout [String: TranscriptAskSession],
        into caseReport: inout CaseReport
    ) async throws {
        guard let question = evaluationCase.question else {
            throw InputError.missingQuestion(evaluationCase.caseID)
        }
        let session: TranscriptAskSession
        if let existing = sessions[evaluationCase.fixture] {
            session = existing
        } else {
            let index = try await TranscriptPassageIndex.build(segments: document.segments)
            session = TranscriptAskSession(store: store, document: document, index: index)
            sessions[evaluationCase.fixture] = session
        }
        var turn: TranscriptAskSession.Turn?
        session.onTurn = { turn = $0 }
        defer {
            session.onTurn = nil
        }
        do {
            let answer = try await session.ask(question) { _ in }
            caseReport.ask = AskReport(answer: answer, turn: turn, document: document)
            caseReport.ok = true
        } catch {
            caseReport.ask = turn.map { AskReport(failedTurn: $0, document: document) }
            throw error
        }
    }

    private enum InputError: LocalizedError {
        case missingRecapWindow(String)
        case missingQuestion(String)

        var errorDescription: String? {
            switch self {
            case .missingRecapWindow(let caseID): "Recap case \(caseID) has no kind or playhead."
            case .missingQuestion(let caseID): "Ask case \(caseID) has no question."
            }
        }
    }

    private static func loadDocument(
        named fixture: String,
        into documents: inout [String: EpisodeTranscriptDocument]
    ) throws -> EpisodeTranscriptDocument {
        if let document = documents[fixture] {
            return document
        }
        let url = inputDirectory.appending(path: "fixtures/\(fixture).json")
        let request = try decode(FixtureRequest.self, from: url)
        let segments = request.segments.map { segment in
            OpenCastTranscriptSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        }
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        let document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: request.episodeID,
            podcastID: request.podcastID,
            sourceAudioURL: "",
            sourceFileByteCount: 0,
            sourceFileSHA256: request.transcript.fingerprint,
            modelIdentifier: "evaluation-fixture",
            modelVersion: "v3",
            modelTreeSHA256: "",
            languageCode: request.transcript.languageCode,
            audioDuration: request.transcript.audioDuration,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: stamp,
            updatedAt: stamp
        )
        documents[fixture] = document
        return document
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private static func save(_ report: Report) {
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            logger.error("report write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Inputs

    private struct Cases: Decodable {
        var datasetVersion: String
        var cases: [EvaluationCase]
    }

    private struct EvaluationCase: Decodable {
        var caseID: String
        var fixture: String
        /// `recap` (default) or `ask`.
        var operation: String?
        var kind: TranscriptRecapWindowKind?
        var playhead: TimeInterval?
        var question: String?

        private enum CodingKeys: String, CodingKey {
            case caseID = "caseId", fixture, operation, kind, playhead, question
        }
    }

    private struct FixtureRequest: Decodable {
        var episodeID: String
        var podcastID: String
        var transcript: FixtureTranscript
        var segments: [FixtureSegment]

        private enum CodingKeys: String, CodingKey {
            case episodeID = "episodeId", podcastID = "podcastId", transcript, segments
        }
    }

    private struct FixtureTranscript: Decodable {
        var languageCode: String
        var audioDuration: TimeInterval
        var fingerprint: String
    }

    private struct FixtureSegment: Decodable {
        var id: Int
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    // MARK: - Report

    private struct Report: Encodable {
        var status = "running"
        var startedAt: Date
        var finishedAt: Date?
        var deviceModel: String
        var systemVersion: String
        var promptVersion: Int
        var askPromptVersion: Int
        var tokenBudget: Int
        var maximumResponseTokens: Int
        var askSessionInputTokenBudget: Int
        var askMaximumToolCallsPerTurn: Int
        var askToolTokenBudget: Int
        var datasetVersion: String?
        var availability: String?
        var modelIdentifier: String?
        var errorMessage: String?
        var cases: [CaseReport] = []
    }

    private struct CaseReport: Encodable {
        var caseID: String
        var fixture: String
        var operation: String
        var kind: TranscriptRecapWindowKind?
        var playhead: TimeInterval?
        var question: String?
        var startedAt: Date
        var finishedAt: Date?
        var ok = false
        var error: ErrorReport?
        var result: ResultReport?
        var attempts: [AttemptReport] = []
        var ask: AskReport?
        var availabilityAfter: String?

        private enum CodingKeys: String, CodingKey {
            case caseID = "caseId", fixture, operation, kind, playhead, question, startedAt, finishedAt, ok, error, result, attempts, ask, availabilityAfter
        }
    }

    private struct AskReport: Encodable {
        var prompt: String
        var answer: String?
        var isAnswerable: Bool?
        var isVerified: Bool?
        var rawCitations: [Int] = []
        var citations: [CitationReport] = []
        var droppedCitationIDs: [Int] = []
        var toolExchanges: [ToolExchangeReport] = []
        var toolCallCount: Int
        var sessionGeneration: Int
        var wasReseeded: Bool
        var sessionInputTokens: Int
        var inputTokens: Int?
        var outputTokens: Int?
        var latency: TimeInterval
        var partialUpdateCount: Int
        var validatedAgainstSegmentCount: Int
        var failure: String?

        private enum CodingKeys: String, CodingKey {
            case prompt, answer, isAnswerable, isVerified, rawCitations, citations
            case droppedCitationIDs = "droppedCitationIds"
            case toolExchanges, toolCallCount, sessionGeneration, wasReseeded, sessionInputTokens
            case inputTokens, outputTokens, latency, partialUpdateCount, validatedAgainstSegmentCount, failure
        }

        init(answer: TranscriptAskAnswer, turn: TranscriptAskSession.Turn?, document: EpisodeTranscriptDocument) {
            self.init(turn: turn, document: document)
            self.answer = answer.text
            isAnswerable = answer.isAnswerable
            isVerified = answer.isVerified
            citations = answer.citations.map { CitationReport($0, document: document) }
            toolCallCount = answer.toolCallCount
            latency = answer.latency ?? turn?.latency ?? 0
        }

        init(failedTurn turn: TranscriptAskSession.Turn, document: EpisodeTranscriptDocument) {
            self.init(turn: turn, document: document)
            failure = turn.failure.map { String(describing: $0) }
        }

        private init(turn: TranscriptAskSession.Turn?, document: EpisodeTranscriptDocument) {
            prompt = turn?.prompt ?? ""
            rawCitations = turn?.answer?.citations ?? []
            droppedCitationIDs = turn?.validation?.droppedCitationIDs ?? []
            toolExchanges = (turn?.toolExchanges ?? []).map(ToolExchangeReport.init)
            toolCallCount = turn?.toolCallCount ?? 0
            sessionGeneration = turn?.sessionGeneration ?? 0
            wasReseeded = turn?.wasReseeded ?? false
            sessionInputTokens = turn?.sessionInputTokenCount ?? 0
            inputTokens = turn?.usage?.inputTokens
            outputTokens = turn?.usage?.outputTokens
            latency = turn?.latency ?? 0
            partialUpdateCount = turn?.partialUpdateCount ?? 0
            validatedAgainstSegmentCount = turn?.validatedAgainstSegmentCount ?? 0
        }
    }

    private struct CitationReport: Encodable {
        var segmentID: Int
        var start: TimeInterval
        var segmentText: String?

        private enum CodingKeys: String, CodingKey {
            case segmentID = "segmentId", start, segmentText
        }

        init(_ citation: TranscriptAskCitation, document: EpisodeTranscriptDocument) {
            segmentID = citation.segmentID
            start = citation.start
            segmentText = document.segments.first { $0.id == citation.segmentID }?.text
        }
    }

    private struct ToolExchangeReport: Encodable {
        var tool: String
        var arguments: String
        var shownSegmentIDs: [Int]
        var outputCharacters: Int
        var isStopMessage: Bool
        var isNoMatch: Bool

        private enum CodingKeys: String, CodingKey {
            case tool, arguments
            case shownSegmentIDs = "shownSegmentIds"
            case outputCharacters, isStopMessage, isNoMatch
        }

        init(_ exchange: TranscriptIntelligenceToolExchange) {
            tool = exchange.toolName
            arguments = exchange.argumentsJSON
            let output = exchange.output ?? ""
            shownSegmentIDs = TranscriptToolOutput.segmentIDs(in: output)
            outputCharacters = output.count
            isStopMessage = output == TranscriptToolBudget.stopMessage
            isNoMatch = output == TranscriptToolOutput.noMatchesMessage
        }
    }

    private struct ErrorReport: Encodable {
        var failure: String
        var message: String

        init(_ error: any Error) {
            if let failure = error as? TranscriptIntelligenceFailure {
                self.failure = String(describing: failure)
                message = failure.userMessage ?? ""
            } else {
                failure = String(describing: type(of: error))
                message = error.localizedDescription
            }
        }
    }

    private struct ResultReport: Encodable {
        var windowStart: TimeInterval
        var windowEnd: TimeInterval
        var windowSegmentCount: Int
        var windowTokenCount: Int
        var isWindowTruncated: Bool
        var bullets: [BulletReport]
        var droppedCitationCount: Int
        var isFromCache: Bool
        var inputTokens: Int?
        var outputTokens: Int?
        var latency: TimeInterval?
        var attempts: Int

        init(_ result: TranscriptRecapResult, document: EpisodeTranscriptDocument) {
            windowStart = result.windowStart
            windowEnd = result.windowEnd
            windowSegmentCount = result.windowSegmentCount
            windowTokenCount = result.windowTokenCount
            isWindowTruncated = result.isWindowTruncated
            bullets = result.bullets.map { BulletReport($0, document: document) }
            droppedCitationCount = result.droppedCitationCount
            isFromCache = result.isFromCache
            inputTokens = result.usage?.inputTokens
            outputTokens = result.usage?.outputTokens
            latency = result.latency
            attempts = result.attempts
        }
    }

    private struct BulletReport: Encodable {
        var text: String
        var segmentID: Int
        var start: TimeInterval
        var segmentText: String?

        private enum CodingKeys: String, CodingKey {
            case text, segmentID = "segmentId", start, segmentText
        }

        init(_ bullet: TranscriptRecapResultBullet, document: EpisodeTranscriptDocument) {
            text = bullet.text
            segmentID = bullet.segmentID
            start = bullet.start
            segmentText = document.segments.first { $0.id == bullet.segmentID }?.text
        }
    }

    private struct AttemptReport: Encodable {
        var windowStart: TimeInterval
        var windowEnd: TimeInterval
        var windowSegmentCount: Int
        var windowTokenCount: Int
        var isWindowTruncated: Bool
        var firstSegmentID: Int?
        var lastSegmentID: Int?
        var rawBullets: [RawBulletReport]
        var droppedCount: Int?
        var failure: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var latency: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case windowStart, windowEnd, windowSegmentCount, windowTokenCount, isWindowTruncated
            case firstSegmentID = "firstSegmentId", lastSegmentID = "lastSegmentId"
            case rawBullets, droppedCount, failure, inputTokens, outputTokens, latency
        }

        init(_ attempt: TranscriptRecapGenerator.Attempt, document: EpisodeTranscriptDocument) {
            windowStart = attempt.window.startTime
            windowEnd = attempt.window.endTime
            windowSegmentCount = attempt.window.segments.count
            windowTokenCount = attempt.window.tokenCount
            isWindowTruncated = attempt.window.isTruncated
            firstSegmentID = attempt.window.segments.first?.id
            lastSegmentID = attempt.window.segments.last?.id
            let ids = attempt.window.segmentIDs
            rawBullets = (attempt.recap?.bullets ?? []).map { bullet in
                RawBulletReport(
                    text: bullet.text,
                    segmentID: bullet.segmentID,
                    resolved: ids.contains(bullet.segmentID),
                    segmentText: document.segments.first { $0.id == bullet.segmentID }?.text
                )
            }
            droppedCount = attempt.validation?.droppedCount
            failure = attempt.failure.map { String(describing: $0) }
            inputTokens = attempt.usage?.inputTokens
            outputTokens = attempt.usage?.outputTokens
            latency = attempt.latency
        }
    }

    private struct RawBulletReport: Encodable {
        var text: String
        var segmentID: Int
        var resolved: Bool
        var segmentText: String?

        private enum CodingKeys: String, CodingKey {
            case text, segmentID = "segmentId", resolved, segmentText
        }
    }
}
#endif
