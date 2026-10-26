/// Which analysis a run performs.
public enum AnalysisFeature: String, Sendable, Hashable, CaseIterable, Codable {
    case adDetection = "ad_detection"
    case chaptersSummary = "chapters_summary"
}

/// Ad-detection numbers the policy bundle does not carry. Each equals the
/// ad-analysis service's constant (`ReferencePolicyTests` reads the source).
enum AdPipelineConstants {
    /// Transport attempts for a window's first request.
    static let initialAttempts = 2
    /// Transport attempts for the one corrective request.
    static let repairTransportAttempts = 1
    /// Longest pause between transport attempts.
    static let maxBackoffSeconds = 10
    /// Longest boundary receipt, in normalized words.
    static let maxReceiptWords = 32
    /// The services' window geometry and per-window span cap, which bound
    /// the whole-episode span ceiling whatever a policy configures.
    static let serviceWindowSegments = 800
    static let serviceWindowOverlapSegments = 120
    static let serviceSpansPerWindow = 32
    /// Longest original evidence quote a repair must still contain, in
    /// normalized words (the services' `MAX_EVIDENCE_WORDS`).
    static let maxPreservedEvidenceWords = 32
}

/// Chapters & Summary numbers the policy bundle does not carry. Each equals
/// the service's constant.
enum ChaptersPipelineConstants {
    /// Model-facing id counts above this start at the escalated level.
    static let escalationSegmentCount = 1_399
    /// The level every retry and every long transcript uses.
    static let escalatedThinking = "high"
    static let escalatedCallTimeoutSeconds = 300
    /// Whole model requests before the run fails.
    static let analysisAttempts = 3
    /// Sends per model request, of which timeouts may use `timeoutResends`.
    static let transportAttempts = 5
    static let timeoutResends = 1
    /// No call starts with less than this left in the run budget.
    static let budgetFloorSeconds = 30
    static let maxRetryDelaySeconds = 30
}

extension JSONValue {
    /// A policy bundle JSON value. Bundle numbers are binary64; the schemas
    /// a bundle carries hold none.
    public init(_ value: AnalysisPolicyJSON) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .number(let number): self = .double(number)
        case .string(let text): self = .string(text)
        case .array(let values): self = .array(values.map(JSONValue.init))
        case .object(let members):
            self = .object(members.map { JSONMember($0.key, JSONValue($0.value)) })
        }
    }
}

extension AnalysisModelEntry {
    /// The model the ad-analysis service runs, as the baked bundle lists it.
    public static var serviceAdDetection: AnalysisModelEntry {
        AnalysisPolicyBundle.baked.features.adDetection.qualifiedModels.first {
            $0.provider == .google && $0.modelID == "gemini-3.8-flash"
        } ?? AnalysisModelEntry(
            provider: .google,
            modelID: "gemini-3.8-flash",
            label: "Gemini 3.8 Flash",
            thinking: "medium",
            maxOutputTokens: 16_384,
            perCallTimeoutSeconds: 120,
            runBudgetSeconds: 570
        )
    }

    /// The model the Chapters & Summary service runs. The bundle lists only
    /// the models qualified for on-device runs, and the service's model is not
    /// among them, so this is the service's own entry.
    public static var serviceChaptersSummary: AnalysisModelEntry {
        AnalysisModelEntry(
            provider: .google,
            modelID: "gemini-3.5-flash",
            label: "Gemini 3.5 Flash",
            thinking: "medium",
            maxOutputTokens: 32_768,
            perCallTimeoutSeconds: 120,
            runBudgetSeconds: 540
        )
    }
}

extension AnalysisPolicy where Settings == AdDetectionPolicy {
    /// What the ad-analysis service runs: the baked settings and its model.
    public static var service: AdDetectionAnalysisPolicy {
        AnalysisPolicy(
            bundleVersion: AnalysisPolicyBundle.baked.bundleVersion,
            source: .baked,
            settings: AnalysisPolicyBundle.baked.features.adDetection,
            model: .serviceAdDetection
        )
    }

    /// The same policy with other settings or another model.
    public func with(settings: AdDetectionPolicy? = nil, model: AnalysisModelEntry? = nil) -> Self {
        AnalysisPolicy(bundleVersion: bundleVersion, source: source, settings: settings ?? self.settings, model: model ?? self.model)
    }
}

extension AnalysisPolicy where Settings == ChaptersSummaryPolicy {
    /// What the Chapters & Summary service runs: the baked settings and its model.
    public static var service: ChaptersSummaryAnalysisPolicy {
        AnalysisPolicy(
            bundleVersion: AnalysisPolicyBundle.baked.bundleVersion,
            source: .baked,
            settings: AnalysisPolicyBundle.baked.features.chaptersSummary,
            model: .serviceChaptersSummary
        )
    }

    public func with(settings: ChaptersSummaryPolicy? = nil, model: AnalysisModelEntry? = nil) -> Self {
        AnalysisPolicy(bundleVersion: bundleVersion, source: source, settings: settings ?? self.settings, model: model ?? self.model)
    }
}
