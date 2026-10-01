import Foundation
import NaturalLanguage

/// Word-vector embeddings for episode lines: the mean of the on-device
/// `NLEmbedding.wordEmbedding` vectors of a text's words (lowercased,
/// stop-listed words skipped), scaled to unit length. The NaturalLanguage
/// objects are not Sendable, so every call creates, uses and drops its own
/// and only plain vectors leave it.
nonisolated enum EpisodeWordVectorEmbedder {
    private static let languageSampleCount = 100
    private static let cancellationStride = 64
    private static let minimumLinesPerTask = 128
    private static let maximumConcurrentTasks = 4

    /// The dominant language of up to the first 100 lines; English when the
    /// recognizer cannot tell.
    static func language(for lines: [EpisodeMetadataLine]) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.prefix(languageSampleCount).map(\.semanticText).joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage, language != .undetermined else {
            return .english
        }
        return language
    }

    /// nil when the language has no word embedding on this device. Long shows
    /// embed in a few concurrent chunks, each with its own embedding; a line's
    /// vector depends only on its text, so the result matches a serial pass.
    @concurrent
    static func index(lines: [EpisodeMetadataLine], language: NLLanguage) async throws -> EpisodeVectorIndex? {
        guard let dimension = NLEmbedding.wordEmbedding(for: language)?.dimension else {
            return nil
        }
        let texts = lines.map(\.semanticText)
        let taskCount = max(
            1,
            min(maximumConcurrentTasks, ProcessInfo.processInfo.activeProcessorCount, texts.count / minimumLinesPerTask)
        )
        let vectors: [[Float]?]
        if taskCount == 1 {
            vectors = try embed(texts, language: language)
        } else {
            let chunkSize = (texts.count + taskCount - 1) / taskCount
            vectors = try await withThrowingTaskGroup(of: (Int, [[Float]?]).self) { group in
                for chunk in 0..<taskCount {
                    let start = min(texts.count, chunk * chunkSize)
                    let end = min(texts.count, start + chunkSize)
                    let slice = Array(texts[start..<end])
                    group.addTask {
                        try (chunk, embed(slice, language: language))
                    }
                }
                var chunks = [[[Float]?]](repeating: [], count: taskCount)
                for try await (chunk, chunkVectors) in group {
                    chunks[chunk] = chunkVectors
                }
                return chunks.flatMap { $0 }
            }
        }
        return EpisodeVectorIndex(dimension: dimension, positions: lines.map(\.position), vectors: vectors)
    }

    /// The vector of the request with its stop-listed words removed; nil when
    /// the language has no embedding or no word of the request is known to it.
    @concurrent
    static func queryVector(_ query: String, language: NLLanguage) async -> [Float]? {
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else {
            return nil
        }
        return vector(
            for: EpisodeMetadataTokenizer.strippingStopWords(query),
            embedding: embedding,
            tokenizer: NLTokenizer(unit: .word)
        )
    }

    private static func embed(_ texts: [String], language: NLLanguage) throws -> [[Float]?] {
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else {
            return Array(repeating: nil, count: texts.count)
        }
        let tokenizer = NLTokenizer(unit: .word)
        var vectors: [[Float]?] = []
        vectors.reserveCapacity(texts.count)
        for (offset, text) in texts.enumerated() {
            if offset.isMultiple(of: cancellationStride) {
                try Task.checkCancellation()
            }
            vectors.append(vector(for: text, embedding: embedding, tokenizer: tokenizer))
        }
        return vectors
    }

    /// The sum runs in Double in word order and is scaled in Float afterwards;
    /// keeping that order keeps every vector, and so every tie, reproducible.
    private static func vector(for text: String, embedding: NLEmbedding, tokenizer: NLTokenizer) -> [Float]? {
        tokenizer.string = text
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var wordCount = 0.0
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            let word = text[range].lowercased()
            guard !EpisodeMetadataTokenizer.stopWords.contains(word),
                  let wordVector = embedding.vector(for: word),
                  wordVector.count == sum.count
            else {
                continue
            }
            for component in sum.indices {
                sum[component] += wordVector[component]
            }
            wordCount += 1
        }
        guard wordCount > 0, !sum.isEmpty else {
            return nil
        }
        return normalized(sum.map { Float($0 / wordCount) })
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else {
            return vector
        }
        return vector.map { $0 / length }
    }
}
