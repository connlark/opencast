import FoundationModels

/// One `LanguageModelSession` on the PCC model. Every turn runs with light
/// reasoning and maps its error before it reaches the store.
nonisolated final class PrivateCloudComputeTranscriptIntelligenceSession: TranscriptIntelligenceSession {
    private let session: LanguageModelSession

    init(session: LanguageModelSession) {
        self.session = session
    }

    var inputTokenCount: Int {
        session.usage.input.totalTokenCount
    }

    func respond(
        to prompt: String,
        options: TranscriptIntelligenceGenerationOptions
    ) async throws -> TranscriptIntelligenceResponse<String> {
        do {
            let response = try await session.respond(
                to: prompt,
                options: Self.generationOptions(options),
                contextOptions: ContextOptions(reasoningLevel: .light)
            )
            return TranscriptIntelligenceResponse(
                content: response.content,
                usage: Self.usage(response.usage),
                toolExchanges: Self.toolExchanges(in: response.transcriptEntries)
            )
        } catch {
            throw TranscriptIntelligenceFailure.failure(mapping: error)
        }
    }

    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        options: TranscriptIntelligenceGenerationOptions
    ) async throws -> TranscriptIntelligenceResponse<Content> {
        do {
            let response = try await session.respond(
                to: prompt,
                generating: type,
                options: Self.generationOptions(options),
                contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .light)
            )
            return TranscriptIntelligenceResponse(
                content: response.content,
                usage: Self.usage(response.usage),
                toolExchanges: Self.toolExchanges(in: response.transcriptEntries)
            )
        } catch {
            throw TranscriptIntelligenceFailure.failure(mapping: error)
        }
    }

    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        options: TranscriptIntelligenceGenerationOptions,
        onPartialContent: @escaping @MainActor (GeneratedContent) -> Void
    ) async throws -> TranscriptIntelligenceResponse<Content> {
        do {
            let stream = session.streamResponse(
                to: prompt,
                generating: type,
                options: Self.generationOptions(options),
                contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .light)
            )
            var last: LanguageModelSession.ResponseStream<Content>.Snapshot?
            for try await snapshot in stream {
                try Task.checkCancellation()
                last = snapshot
                await onPartialContent(snapshot.rawContent)
            }
            guard let last else {
                throw TranscriptIntelligenceFailure.malformedOutput
            }
            let content: Content
            do {
                content = try Content(last.rawContent)
            } catch {
                throw TranscriptIntelligenceFailure.malformedOutput
            }
            return TranscriptIntelligenceResponse(
                content: content,
                usage: Self.usage(last.usage),
                toolExchanges: Self.toolExchanges(in: last.transcriptEntries)
            )
        } catch {
            throw TranscriptIntelligenceFailure.failure(mapping: error)
        }
    }

    private static func generationOptions(_ options: TranscriptIntelligenceGenerationOptions) -> GenerationOptions {
        var generation = GenerationOptions(maximumResponseTokens: options.maximumResponseTokens)
        generation.toolCallingMode = switch options.toolCalling {
        case .allowed: .allowed
        case .required: .required
        case .disallowed: .disallowed
        }
        return generation
    }

    private static func usage(_ usage: LanguageModelSession.Usage) -> TranscriptIntelligenceUsage {
        TranscriptIntelligenceUsage(
            inputTokens: usage.input.totalTokenCount,
            outputTokens: usage.output.totalTokenCount
        )
    }

    /// Pairs each tool call in the turn with its output by call id, falling
    /// back to the first unanswered call of the same tool.
    private static func toolExchanges(in entries: ArraySlice<Transcript.Entry>) -> [TranscriptIntelligenceToolExchange] {
        var exchanges: [TranscriptIntelligenceToolExchange] = []
        var callIDs: [String] = []
        for entry in entries {
            switch entry {
            case .toolCalls(let calls):
                for call in calls {
                    exchanges.append(TranscriptIntelligenceToolExchange(
                        toolName: call.toolName,
                        argumentsJSON: call.arguments.jsonString,
                        output: nil
                    ))
                    callIDs.append(call.id)
                }
            case .toolOutput(let output):
                let index = callIDs.firstIndex(of: output.id)
                    ?? exchanges.firstIndex { $0.toolName == output.toolName && $0.output == nil }
                if let index {
                    exchanges[index].output = text(of: output.segments)
                }
            default:
                break
            }
        }
        return exchanges
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: ""
            }
        }
        .joined(separator: "\n")
    }
}
