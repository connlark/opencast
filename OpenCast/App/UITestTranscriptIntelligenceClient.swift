#if DEBUG
import Foundation
import FoundationModels

/// UI-test stand-in for the PCC client: eligibility comes from the launch
/// environment, and an available client answers every structured turn with
/// canned content that cites the seeded transcript's two lines (a recap, or
/// an answer with a scripted tool exchange), so the sheets can render on a
/// simulator whose own eligibility follows the host Mac.
nonisolated final class UITestTranscriptIntelligenceClient: TranscriptIntelligenceModelClient {
    static let availabilityEnvironmentKey = "OPENCAST_UI_TEST_TRANSCRIPT_INTELLIGENCE_AVAILABILITY"
    /// `answerable` (default), `unanswerable`, or `unverified`.
    static let askAnswerEnvironmentKey = "OPENCAST_UI_TEST_TRANSCRIPT_ASK_ANSWER"

    let modelIdentifier = "ui-test"
    let modelAvailability: TranscriptIntelligenceModelAvailability
    let quota = TranscriptIntelligenceQuotaSnapshot()

    init(modelAvailability: TranscriptIntelligenceModelAvailability) {
        self.modelAvailability = modelAvailability
    }

    static func resolve(environment: [String: String]) -> TranscriptIntelligenceModelAvailability? {
        switch environment[availabilityEnvironmentKey] {
        case "available": .available
        case "deviceNotEligible": .deviceNotEligible
        case "appleIntelligenceNotEnabled": .appleIntelligenceNotEnabled
        case "systemNotReady": .systemNotReady
        default: nil
        }
    }

    func tokenCount(for text: String) async throws -> Int {
        text.count / 4
    }

    func showLimitIncreaseSuggestion() {}

    func makeSession(instructions: String, tools: [any Tool]) -> any TranscriptIntelligenceSession {
        UITestTranscriptIntelligenceSession()
    }
}

nonisolated final class UITestTranscriptIntelligenceSession: TranscriptIntelligenceSession {
    private(set) var inputTokenCount = 0

    private static let cannedRecapJSON = """
        {"bullets":[
          {"text":"The host opens with a welcome to a deterministic transcript.","segmentID":0},
          {"text":"A short sponsor read for Seed Sponsor follows the welcome.","segmentID":1},
          {"text":"The episode then continues past the sponsor read.","segmentID":1}
        ]}
        """

    private static let cannedAnswerText = "The episode opens with a welcome and a short read for Seed Sponsor."

    private static var cannedAnswerJSON: String {
        let variant = ProcessInfo.processInfo.environment[UITestTranscriptIntelligenceClient.askAnswerEnvironmentKey]
        switch variant {
        case "unanswerable":
            return #"{"answer":"The transcript does not say.","citations":[],"isAnswerable":false}"#
        case "unverified":
            return #"{"answer":"\#(cannedAnswerText)","citations":[41],"isAnswerable":true}"#
        default:
            return #"{"answer":"\#(cannedAnswerText)","citations":[1,0],"isAnswerable":true}"#
        }
    }

    /// What the seeded two-line transcript's search tool would have shown.
    private static let cannedToolExchange = TranscriptIntelligenceToolExchange(
        toolName: "searchTranscript",
        argumentsJSON: #"{"query": "welcome sponsor"}"#,
        output: """
            \(TranscriptIntelligencePrompts.transcriptDataFraming)

            [#0 0:00–0:04] Welcome to a deterministic transcript.
            [#1 0:04–0:09] This row is brought to you by Seed Sponsor.
            """
    )

    func respond(
        to prompt: String,
        options: TranscriptIntelligenceGenerationOptions
    ) async throws -> TranscriptIntelligenceResponse<String> {
        inputTokenCount += prompt.count / 4
        return TranscriptIntelligenceResponse(content: "", usage: TranscriptIntelligenceUsage(inputTokens: inputTokenCount), toolExchanges: [])
    }

    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        options: TranscriptIntelligenceGenerationOptions
    ) async throws -> TranscriptIntelligenceResponse<Content> {
        try await respond(to: prompt, generating: type, options: options) { _ in }
    }

    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        options: TranscriptIntelligenceGenerationOptions,
        onPartialContent: @escaping @MainActor (GeneratedContent) -> Void
    ) async throws -> TranscriptIntelligenceResponse<Content> {
        inputTokenCount += prompt.count / 4
        let isAnswer = type == TranscriptAnswer.self
        let json = isAnswer ? Self.cannedAnswerJSON : Self.cannedRecapJSON
        let content: Content
        do {
            let generated = try GeneratedContent(json: json)
            if isAnswer {
                // Two partial snapshots, then the full content, so the sheet's
                // streaming row is exercised.
                let prefix = String(Self.cannedAnswerText.prefix(24))
                await onPartialContent(try GeneratedContent(json: #"{"answer":"\#(prefix)"}"#))
                try await Task.sleep(for: .milliseconds(150))
            }
            await onPartialContent(generated)
            content = try Content(generated)
        } catch {
            throw TranscriptIntelligenceFailure.malformedOutput
        }
        return TranscriptIntelligenceResponse(
            content: content,
            usage: TranscriptIntelligenceUsage(inputTokens: inputTokenCount, outputTokens: 60),
            toolExchanges: isAnswer ? [Self.cannedToolExchange] : []
        )
    }
}
#endif
