import FoundationModels
@testable import OpenCast

/// Scripted stand-in for the PCC client: eligibility and quota are plain
/// settable values; every session pops the shared scripted turns in order.
nonisolated final class ScriptedTranscriptIntelligenceClient: TranscriptIntelligenceModelClient {
    enum Turn {
        case text(String)
        case json(String)
        /// A structured turn that also reports the tool exchanges the model
        /// made, as the PCC session would.
        case answer(json: String, toolExchanges: [TranscriptIntelligenceToolExchange])
        case failure(TranscriptIntelligenceFailure)
        /// Never returns until cancelled, like a PCC turn that hangs.
        case hang
    }

    var modelIdentifier = "scripted"
    var modelAvailability = TranscriptIntelligenceModelAvailability.available
    var quota = TranscriptIntelligenceQuotaSnapshot()
    var turns: [Turn] = []
    /// Token count charged per session for each prompt, so tests can push a
    /// session past the Ask input budget deterministically.
    var inputTokensPerPrompt: ((String) -> Int) = { $0.count / 4 }
    private(set) var sessions: [ScriptedTranscriptIntelligenceSession] = []

    private(set) var limitIncreaseSuggestionShowCount = 0

    func tokenCount(for text: String) async throws -> Int {
        text.count / 4
    }

    func showLimitIncreaseSuggestion() {
        limitIncreaseSuggestionShowCount += 1
    }

    func makeSession(instructions: String, tools: [any Tool]) -> any TranscriptIntelligenceSession {
        let session = ScriptedTranscriptIntelligenceSession(
            client: self,
            instructions: instructions,
            toolNames: tools.map(\.name)
        )
        sessions.append(session)
        return session
    }

    fileprivate func nextTurn() -> Turn? {
        turns.isEmpty ? nil : turns.removeFirst()
    }
}

nonisolated final class ScriptedTranscriptIntelligenceSession: TranscriptIntelligenceSession {
    let instructions: String
    let toolNames: [String]
    private(set) var prompts: [String] = []
    private(set) var inputTokenCount = 0
    private(set) var partialUpdateCounts: [Int] = []
    private unowned let client: ScriptedTranscriptIntelligenceClient

    fileprivate init(client: ScriptedTranscriptIntelligenceClient, instructions: String, toolNames: [String]) {
        self.client = client
        self.instructions = instructions
        self.toolNames = toolNames
    }

    func respond(
        to prompt: String,
        options: TranscriptIntelligenceGenerationOptions
    ) async throws -> TranscriptIntelligenceResponse<String> {
        let text = switch try await consume(prompt) {
        case .text(let text), .json(let text): text
        case .answer(let json, _): json
        case .failure, .hang: ""
        }
        return TranscriptIntelligenceResponse(content: text, usage: usage(prompt, text), toolExchanges: [])
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
        let json: String
        let exchanges: [TranscriptIntelligenceToolExchange]
        switch try await consume(prompt) {
        case .json(let scripted):
            json = scripted
            exchanges = []
        case .answer(let scripted, let scriptedExchanges):
            json = scripted
            exchanges = scriptedExchanges
        default:
            throw TranscriptIntelligenceFailure.malformedOutput
        }
        let content: Content
        let generated: GeneratedContent
        do {
            generated = try GeneratedContent(json: json)
            content = try Content(generated)
        } catch {
            throw TranscriptIntelligenceFailure.malformedOutput
        }
        // A scripted stream: one half-formed snapshot, then the full one.
        var partials = 0
        if let answer = try? generated.value(String.self, forProperty: "answer"), answer.count > 4 {
            let half = String(answer.prefix(answer.count / 2))
            if let partial = try? GeneratedContent(json: #"{"answer":"\#(half)"}"#) {
                await onPartialContent(partial)
                partials += 1
            }
        }
        await onPartialContent(generated)
        partials += 1
        partialUpdateCounts.append(partials)
        return TranscriptIntelligenceResponse(content: content, usage: usage(prompt, json), toolExchanges: exchanges)
    }

    private func consume(_ prompt: String) async throws -> ScriptedTranscriptIntelligenceClient.Turn {
        prompts.append(prompt)
        guard let turn = client.nextTurn() else {
            throw TranscriptIntelligenceFailure.unknown("no scripted turn")
        }
        switch turn {
        case .failure(let failure):
            throw failure
        case .hang:
            try await Task.sleep(for: .seconds(3_600))
            throw CancellationError()
        case .text, .json, .answer:
            return turn
        }
    }

    private func usage(_ prompt: String, _ output: String) -> TranscriptIntelligenceUsage {
        inputTokenCount += client.inputTokensPerPrompt(prompt)
        return TranscriptIntelligenceUsage(inputTokens: inputTokenCount, outputTokens: output.count / 4)
    }
}
