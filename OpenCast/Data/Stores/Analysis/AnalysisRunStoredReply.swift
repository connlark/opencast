import CryptoKit
import Foundation
import OpenCastAnalysis

/// Which request a kept reply answers: the request's purpose and the
/// SHA-256 of its exact payload, so a reply is reused only for the same
/// bytes the provider answered.
nonisolated struct AnalysisRunReplyKey: Codable, Sendable, Hashable {
    /// `ad_window_<n>`, `ad_repair_<n>` or `chapters_<n>`.
    var purpose: String
    var payloadSHA256: String

    init(purpose: String, payloadSHA256: String) {
        self.purpose = purpose
        self.payloadSHA256 = payloadSHA256
    }

    init(_ request: AnalysisProviderRequest) {
        purpose = switch request.purpose {
        case .adWindow(let index): "ad_window_\(index)"
        case .adRepair(let index): "ad_repair_\(index)"
        case .chapters(let attempt): "chapters_\(attempt)"
        }
        payloadSHA256 = SHA256.hash(data: Data(request.payloadText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    enum CodingKeys: String, CodingKey {
        case purpose
        case payloadSHA256 = "payload_sha256"
    }
}

/// A provider reply as a resumed run reads it back.
nonisolated enum AnalysisRunStoredReply: Codable, Sendable, Hashable {
    case geminiBody(String)
    case answer(texts: [String], finishReason: String?, usage: Usage?)

    struct Usage: Codable, Sendable, Hashable {
        var prompt: UInt64
        var candidates: UInt64
        var thoughts: UInt64
        var total: UInt64
    }

    init(_ reply: AnalysisProviderReply) {
        switch reply {
        case .geminiBody(let body):
            self = .geminiBody(body)
        case .answer(let answer):
            self = .answer(
                texts: answer.texts,
                finishReason: answer.finishReason,
                usage: answer.usage.map {
                    Usage(prompt: $0.promptTokenCount, candidates: $0.candidatesTokenCount, thoughts: $0.thoughtsTokenCount, total: $0.totalTokenCount)
                }
            )
        }
    }

    var reply: AnalysisProviderReply {
        switch self {
        case .geminiBody(let body):
            .geminiBody(body)
        case .answer(let texts, let finishReason, let usage):
            .answer(AnalysisProviderAnswer(
                texts: texts,
                finishReason: finishReason,
                usage: usage.map {
                    AnalysisUsage(promptTokenCount: $0.prompt, candidatesTokenCount: $0.candidates, thoughtsTokenCount: $0.thoughts, totalTokenCount: $0.total)
                }
            ))
        }
    }
}

nonisolated struct AnalysisRunReplyEntry: Codable, Sendable {
    var key: AnalysisRunReplyKey
    var reply: AnalysisRunStoredReply
}
