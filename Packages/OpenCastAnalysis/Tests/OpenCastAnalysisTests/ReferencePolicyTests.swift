import Foundation
@testable import OpenCastAnalysis
import Testing

/// The service policies the pipeline runs under, and the pipeline numbers
/// the bundle does not carry, must equal the analysis services' source:
/// prompts byte for byte, the schemas, and every constant.
@Suite("Service policy")
struct ReferencePolicyTests {
    let ad = AdDetectionAnalysisPolicy.service
    let chapters = ChaptersSummaryAnalysisPolicy.service

    func rustConstant(_ file: String, _ name: String) throws -> String {
        let source = try TestSupport.repositoryText(file)
        let pattern = try Regex("(?m)^\\s*pub const \(name): [^=]+= ([^;]+);")
        let match = try #require(source.firstMatch(of: pattern))
        let value = String(match.output[1].substring!).trimmingCharacters(in: .whitespaces)
        // Digit separators only; quoted strings keep their underscores.
        return value.hasPrefix("\"") ? value : value.replacing("_", with: "")
    }

    func rustRawString(_ file: String, _ name: String) throws -> String {
        let source = try TestSupport.repositoryText(file)
        let start = try #require(source.range(of: "\(name): &str = r#\""))
        let end = try #require(source.range(of: "\"#;", range: start.upperBound..<source.endIndex))
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// `promo_v3::schema()`: the base span schema with closed objects and both
    /// boundary receipts required.
    func rustAdSchema() throws -> JSONValue {
        guard case .object(var root) = try JSONParser.parse(try rustRawString("Server/AdAnalysisWorker/src/prompt.rs", "RESPONSE_SCHEMA")) else {
            throw StrictDecodingError("schema is not an object")
        }
        root.setMember("additionalProperties", .bool(false))
        root.updateObjectMember("properties") { properties in
            properties.updateObjectMember("spans") { spans in
                spans.updateObjectMember("items") { item in
                    item.setMember("additionalProperties", .bool(false))
                    item.updateObjectMember("properties") { fields in
                        fields.setMember("start_quote", .object(["type": .string("string")]))
                        fields.setMember("end_quote", .object(["type": .string("string")]))
                    }
                    item.updateMember("required") { required in
                        guard case .array(var names) = required else { return }
                        names += [.string("start_quote"), .string("end_quote")]
                        required = .array(names)
                    }
                }
            }
        }
        return .object(root)
    }

    @Test("Prompts and schemas equal the services' sources")
    func texts() throws {
        #expect(ad.settings.prompt == (try TestSupport.repositoryText("Server/AdAnalysisWorker/src/promo_v3_prompt.txt")))
        #expect(JSONValue(ad.settings.responseSchema).sortedKeys() == (try rustAdSchema()).sortedKeys())
        #expect(chapters.settings.prompt == (try rustRawString("Server/TranscriptAnalysisWorker/src/prompt.rs", "TRANSCRIPT_ANALYSIS_V2_RULES")))
        #expect(JSONValue(chapters.settings.responseSchema).sortedKeys()
            == (try JSONParser.parse(try rustRawString("Server/TranscriptAnalysisWorker/src/prompt.rs", "RESPONSE_SCHEMA"))).sortedKeys())
    }

    @Test("Ad-detection numbers equal the services' constants")
    func adConstants() throws {
        let settings = ad.settings
        let model = ad.model
        let src = "Server/AdAnalysisWorker/src/"
        #expect(String(settings.window.segments) == (try rustConstant(src + "v3_windowing.rs", "WINDOW_SEGMENTS")))
        #expect(String(settings.window.overlap) == (try rustConstant(src + "v3_windowing.rs", "OVERLAP_SEGMENTS")))
        #expect(String(settings.window.maxInFlight) == (try rustConstant(src + "v3_windowing.rs", "CONCURRENT_WINDOWS")))
        #expect(String(settings.limits.spansPerWindow) == (try rustConstant(src + "promo_v3.rs", "MAX_BREAKS_PER_WINDOW")))
        #expect(Double(try rustConstant(src + "promo_v3.rs", "MAX_BREAK_SECONDS")) == settings.limits.maxBreakSeconds)
        #expect(String(settings.limits.evidenceWords) == (try rustConstant(src + "promo_v3.rs", "MAX_EVIDENCE_WORDS")))
        #expect(String(AdPipelineConstants.serviceWindowSegments) == (try rustConstant(src + "v3_windowing.rs", "WINDOW_SEGMENTS")))
        #expect(String(AdPipelineConstants.serviceWindowOverlapSegments) == (try rustConstant(src + "v3_windowing.rs", "OVERLAP_SEGMENTS")))
        #expect(String(AdPipelineConstants.serviceSpansPerWindow) == (try rustConstant(src + "promo_v3.rs", "MAX_BREAKS_PER_WINDOW")))
        #expect(String(AdPipelineConstants.maxPreservedEvidenceWords) == (try rustConstant(src + "promo_v3.rs", "MAX_EVIDENCE_WORDS")))
        #expect(String(settings.repair.feedbackBytes) == (try rustConstant(src + "promo_v3.rs", "MAX_REPAIR_FEEDBACK_BYTES")))
        #expect(String(AdAnswerParser.maxAnswerBytes) == (try rustConstant(src + "promo_v3.rs", "MAX_MODEL_JSON_BYTES")))
        #expect(Double(try rustConstant(src + "promo_v3.rs", "MAX_MIXED_BOUNDARY_SECONDS")) == AdValidator.maxMixedBoundarySeconds)
        #expect(Double(try rustConstant(src + "validation.rs", "AD_BUDGET_EPISODE_FRACTION")) == settings.limits.budgetFraction)
        #expect(Double(try rustConstant(src + "validation.rs", "AD_BUDGET_FLOOR_SECONDS")) == settings.limits.budgetFloorSeconds)
        #expect(Double(try rustConstant(src + "validation.rs", "DECLARED_DURATION_MIN_FRACTION")) == AdValidator.declaredDurationMinimumFraction)
        #expect(String(AdPipelineConstants.initialAttempts) == (try rustConstant(src + "policy.rs", "V3_INITIAL_ATTEMPTS")))
        #expect(String(AdPipelineConstants.repairTransportAttempts) == (try rustConstant(src + "policy.rs", "V3_REPAIR_ATTEMPTS")))
        #expect(settings.repair.attempts == 1)
        #expect(String(AdPipelineConstants.maxBackoffSeconds) == (try rustConstant(src + "policy.rs", "V3_MAX_BACKOFF_SECONDS")))
        #expect(String(model.runBudgetSeconds) == (try rustConstant(src + "policy.rs", "V3_EXECUTION_SECONDS")))
        #expect(String(model.perCallTimeoutSeconds) == (try rustConstant(src + "policy.rs", "V3_MAX_CALL_SECONDS")))
        #expect("\"\(model.modelID)\"" == (try rustConstant(src + "policy.rs", "V3_MODEL")))
        #expect("\"\(model.thinking)\"" == (try rustConstant(src + "policy.rs", "V3_THINKING")))
        #expect("\"\(settings.revision)\"" == (try rustConstant(src + "policy.rs", "V3_REVISION")))
        #expect("\"\(settings.policy)\"" == (try rustConstant(src + "promo_v3.rs", "POLICY")))
        #expect(String(model.maxOutputTokens) == (try rustConstant(src + "prompt.rs", "GEMINI_MAX_OUTPUT_TOKENS")))
        // The receipt cap is the literal in receipt_position.
        #expect((try TestSupport.repositoryText(src + "promo_v3.rs"))
            .contains("if quote.is_empty() || quote.len() > \(AdPipelineConstants.maxReceiptWords) {"))
    }

    @Test("Chapters numbers equal the services' constants")
    func chaptersConstants() throws {
        let settings = chapters.settings
        let model = chapters.model
        let src = "Server/TranscriptAnalysisWorker/src/"
        #expect(String(settings.coalescing.aboveSegments) == (try rustConstant(src + "coalescing.rs", "COALESCING_TRIGGER_SEGMENT_COUNT")))
        #expect(Double(try rustConstant(src + "coalescing.rs", "MIN_UNIT_SPAN_BEFORE_CLOSE")) == settings.coalescing.unitSeconds)
        #expect(String(settings.coalescing.unitChars) == (try rustConstant(src + "coalescing.rs", "UNIT_JOIN_CHAR_LIMIT")))
        #expect(Double(try rustConstant(src + "coalescing.rs", "GAP_BREAK_SECONDS")) == settings.coalescing.gapSeconds)
        #expect(String(settings.coalescing.maxUnits) == (try rustConstant(src + "types.rs", "MAX_MODEL_UNITS")))
        #expect(String(settings.chapterCap.min) == (try rustConstant(src + "validation.rs", "MIN_CHAPTERS_FLOOR")))
        #expect(Double(try rustConstant(src + "validation.rs", "CHAPTER_SECONDS_PER_CHAPTER")) == settings.chapterCap.secondsPerChapter)
        #expect(String(ChaptersPipelineConstants.escalationSegmentCount) == (try rustConstant(src + "thinking.rs", "THINKING_ESCALATION_SEGMENT_COUNT")))
        #expect(String(ChaptersPipelineConstants.escalatedCallTimeoutSeconds) == (try rustConstant(src + "retry.rs", "GEMINI_CALL_TIMEOUT_HIGH_SECONDS")))
        #expect(String(model.perCallTimeoutSeconds) == (try rustConstant(src + "retry.rs", "GEMINI_CALL_TIMEOUT_MEDIUM_SECONDS")))
        #expect(String(model.runBudgetSeconds) == (try rustConstant(src + "retry.rs", "ANALYSIS_RUN_BUDGET_SECONDS")))
        #expect(String(ChaptersPipelineConstants.budgetFloorSeconds) == (try rustConstant(src + "retry.rs", "ANALYSIS_BUDGET_FLOOR_SECONDS")))
        #expect(String(ChaptersPipelineConstants.timeoutResends) == (try rustConstant(src + "retry.rs", "MAX_TIMEOUT_RESENDS")))
        #expect(String(ChaptersPipelineConstants.maxRetryDelaySeconds) == (try rustConstant(src + "retry.rs", "MAX_RETRY_DELAY_SECONDS")))
        #expect(String(model.maxOutputTokens) == (try rustConstant(src + "prompt.rs", "GEMINI_MAX_OUTPUT_TOKENS")))
        #expect("\"\(model.modelID)\"" == (try rustConstant(src + "types.rs", "GEMINI_MODEL_DEFAULT")))
        #expect("\"\(settings.policy)\"" == (try rustConstant(src + "types.rs", "POLICY_NAME")))
        let analysis = try TestSupport.repositoryText(src + "analysis.rs")
        #expect(analysis.contains("const MAX_GEMINI_ATTEMPTS: usize = \(ChaptersPipelineConstants.transportAttempts);"))
        #expect(analysis.contains("const MAX_ANALYSIS_ATTEMPTS: usize = \(ChaptersPipelineConstants.analysisAttempts);"))
        #expect((try TestSupport.repositoryText(src + "thinking.rs")).contains("\"\(ChaptersPipelineConstants.escalatedThinking)\""))
    }
}
