import Foundation
@testable import OpenCastAnalysis
import Testing

/// Replays every synthetic golden case through the Swift pipeline and
/// requires the output to equal what the services' eval bridges produced
/// for the same inputs (`Packages/OpenCastAnalysis/scripts/generate-parity-goldens.py`).
@Suite("Parity goldens")
struct ParityGoldenTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let value: JSONValue
        var testDescription: String { name }
    }

    static let goldens: JSONValue = (try? TestSupport.fixture("parity-goldens.json")) ?? .null

    static let cases: [Case] = (goldens["cases"]?.arrayValue ?? []).map {
        Case(name: $0["name"]?.stringValue ?? "?", value: $0)
    }

    @Test("Goldens are present")
    func goldensPresent() {
        #expect(Self.cases.count >= 50)
    }

    /// A provider body: its text, or pieces `[[text, count], ...]`
    /// concatenated in order (how the deep-nesting goldens store a body of
    /// a mebibyte of brackets).
    static func body(_ value: JSONValue?) throws -> String {
        if let text = value?.stringValue { return text }
        var text = ""
        for piece in try #require(value?["pieces"]?.arrayValue) {
            let part = try #require(piece.arrayValue?.first?.stringValue)
            guard case .number(.unsigned(let count))? = piece.arrayValue?.last else {
                Issue.record("piece without a count")
                return text
            }
            text += String(repeating: part, count: Int(count))
        }
        return text
    }

    @Test("Swift output equals the services' bridge output", arguments: cases)
    func matchesBridge(_ testCase: Case) async throws {
        let value = testCase.value
        let fixtureName = try #require(value["fixture"]?.stringValue)
        let fixture = try #require(Self.goldens["fixtures"]?[fixtureName])
        let model = value["model"]?.stringValue ?? ""
        let thinking = value["thinking"]?.stringValue
        let actual: JSONValue
        switch (value["feature"]?.stringValue, value["command"]?.stringValue) {
        case ("ads", "run"):
            let service = AdDetectionAnalysisPolicy.service
            var settings = service.settings
            settings.window.maxInFlight = 1
            var entry = service.model
            entry.modelID = model
            let policy = service.with(settings: settings, model: entry)
            let request = try AdAnalysisRequest(json: fixture)
            let replies = try AnalysisReplay.replies(try #require(value["replies"]))
            actual = await AnalysisReplay.runAds(request, replies: replies, policy: policy, canonicalThinking: thinking)
            if case .string = actual["response_json"] ?? .null {
                let concurrent = await AnalysisReplay.runAds(
                    request,
                    replies: replies,
                    policy: service.with(model: entry),
                    canonicalThinking: thinking
                )
                #expect(concurrent["response_json"] == actual["response_json"], "concurrent windows changed the response")
            }
        case ("ads", "validate"):
            var settings = AdDetectionAnalysisPolicy.service.settings
            if case .number(.unsigned(let segments))? = value["window_segments"] { settings.window.segments = Int(segments) }
            if case .number(.unsigned(let overlap))? = value["window_overlap"] { settings.window.overlap = Int(overlap) }
            actual = AnalysisTraceJSON.validation(AdValidator.validate(
                try AdAnalysisRequest(json: fixture),
                try AdModelOutput(json: try #require(value["output"])),
                policy: settings
            ))
        case ("ads", "parse"):
            actual = AnalysisTraceJSON.parsed(AdAnswerParser.parse(geminiBody: try Self.body(value["body"])))
        case ("ads", "preserves"):
            let request = try AdAnalysisRequest(json: fixture)
            let before = try AdModelOutput(json: try #require(value["before"]))
            let after = try AdModelOutput(json: try #require(value["after"]))
            let reference = AdDetectionAnalysisPolicy.service.settings
            var tightened = reference
            if case .number(.unsigned(let words))? = value["evidence_words"] { tightened.limits.evidenceWords = Int(words) }
            let checked = AdValidator.validateWindow(request, after, policy: reference)
            actual = .object([
                "verified_breaks": .bool(AdRepair.preservesVerifiedBreaks(
                    AdValidator.validateWindow(request, before, policy: reference),
                    checked
                )),
                "candidate_evidence": checked.isComplete
                    ? .bool(AdRepair.preservesCandidateEvidence(request, before: before, after: after, policy: tightened))
                    : .null,
            ])
        case ("ads", "render"):
            actual = AnalysisReplay.renderAds(
                try AdAnalysisRequest(json: fixture),
                policy: .service,
                canonicalThinking: thinking
            )
        case ("chapters", "run"):
            var entry = ChaptersSummaryAnalysisPolicy.service.model
            entry.modelID = model
            actual = await AnalysisReplay.runChapters(
                try TranscriptAnalysisRequest(json: fixture),
                replies: try AnalysisReplay.replies(try #require(value["replies"])),
                policy: ChaptersSummaryAnalysisPolicy.service.with(model: entry)
            )
        case ("chapters", "validate"):
            let replyJSON = JSONValue.object(["body": .string(try Self.body(value["reply"]?["body"]))])
            let reply = try #require(try AnalysisReplay.reply(replyJSON))
            actual = AnalysisReplay.validateChapters(
                try TranscriptAnalysisRequest(json: fixture),
                reply: reply,
                policy: .service
            )
        case ("chapters", "render"):
            actual = AnalysisReplay.renderChapters(try TranscriptAnalysisRequest(json: fixture), policy: .service)
        default:
            Issue.record("unknown case kind")
            return
        }
        let expected = try #require(value["expected"]).sortedKeys()
        let observed = TestSupport.digestPayloads(actual).sortedKeys()
        #expect(observed == expected, "\(testCase.name): \(firstDifference(observed, expected) ?? "")")
    }

    /// The path of the first differing value, for a readable failure.
    func firstDifference(_ lhs: JSONValue, _ rhs: JSONValue, path: String = "$") -> String? {
        switch (lhs, rhs) {
        case let (.object(left), .object(right)):
            let keys = Set(left.map(\.key)).union(right.map(\.key)).sorted()
            for key in keys {
                guard let l = left.first(where: { $0.key == key })?.value,
                      let r = right.first(where: { $0.key == key })?.value
                else { return "\(path).\(key) present on one side only" }
                if let difference = firstDifference(l, r, path: "\(path).\(key)") { return difference }
            }
            return nil
        case let (.array(left), .array(right)):
            guard left.count == right.count else { return "\(path) has \(left.count) vs \(right.count) elements" }
            for (index, pair) in zip(left, right).enumerated() {
                if let difference = firstDifference(pair.0, pair.1, path: "\(path)[\(index)]") { return difference }
            }
            return nil
        default:
            return lhs == rhs ? nil : "\(path): \(JSONWriter.string(lhs).prefix(200)) vs \(JSONWriter.string(rhs).prefix(200))"
        }
    }
}
