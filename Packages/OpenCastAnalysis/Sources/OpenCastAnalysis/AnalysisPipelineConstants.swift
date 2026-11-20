public enum AnalysisFeature: String, Sendable, Hashable, CaseIterable, Codable {
    case adDetection = "ad_detection"
    case chaptersSummary = "chapters_summary"
}

/// Each value must equal the ad-analysis service's constant of the same meaning.
enum AdPipelineConstants {
    static let initialAttempts = 2
    static let repairTransportAttempts = 1
    static let maxBackoffSeconds = 10
    /// Longest boundary receipt, in normalized words.
    static let maxReceiptWords = 32
    static let serviceWindowSegments = 800
    static let serviceWindowOverlapSegments = 120
    static let serviceSpansPerWindow = 32
    /// In normalized words; the services' `MAX_EVIDENCE_WORDS`.
    static let maxPreservedEvidenceWords = 32
}

enum AdTrialRunConstants {
    /// Twelve 120-second first sends plus 300 s to spare, counted from when the run's budget is
    /// made. Retries, repairs and waits draw on the same deadline.
    static let runBudgetSeconds = 1_740
    /// No send starts with less than this left, and no pause leaves less.
    static let sendFloorSeconds = 30
}

/// Each value must equal the Chapters & Summary service's constant of the same meaning.
enum ChaptersPipelineConstants {
    /// Model-facing id counts above this start at the escalated level.
    static let escalationSegmentCount = 1_399
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
    /// Every number becomes a binary64, which is safe because a bundle's schemas hold no numbers.
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

    /// Not looked up: the bundle lists only on-device models, and the service's model is not one.
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
    public static var service: AdDetectionAnalysisPolicy {
        AnalysisPolicy(
            bundleVersion: AnalysisPolicyBundle.baked.bundleVersion,
            source: .baked,
            settings: AnalysisPolicyBundle.baked.features.adDetection,
            model: .serviceAdDetection
        )
    }

    public func with(
        settings: AdDetectionPolicy? = nil,
        model: AnalysisModelEntry? = nil,
        executionBudget: AnalysisExecutionBudget? = nil
    ) -> Self {
        AnalysisPolicy(
            bundleVersion: bundleVersion,
            source: source,
            settings: settings ?? self.settings,
            model: model ?? self.model,
            executionBudget: executionBudget ?? self.executionBudget
        )
    }
}

extension AnalysisPolicy where Settings == ChaptersSummaryPolicy {
    public static var service: ChaptersSummaryAnalysisPolicy {
        AnalysisPolicy(
            bundleVersion: AnalysisPolicyBundle.baked.bundleVersion,
            source: .baked,
            settings: AnalysisPolicyBundle.baked.features.chaptersSummary,
            model: .serviceChaptersSummary
        )
    }

    public func with(settings: ChaptersSummaryPolicy? = nil, model: AnalysisModelEntry? = nil) -> Self {
        AnalysisPolicy(
            bundleVersion: bundleVersion,
            source: source,
            settings: settings ?? self.settings,
            model: model ?? self.model,
            executionBudget: executionBudget
        )
    }
}
