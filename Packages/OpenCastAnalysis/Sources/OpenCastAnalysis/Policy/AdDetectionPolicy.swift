public struct AdDetectionPolicy: Sendable, Equatable, Decodable {
    public struct Window: Sendable, Equatable, Decodable {
        public var segments: Int
        public var overlap: Int
        /// Windows dispatched at once on one key.
        public var maxInFlight: Int

        enum CodingKeys: String, CodingKey {
            case segments
            case overlap
            case maxInFlight = "max_in_flight"
        }
    }

    public struct Limits: Sendable, Equatable, Decodable {
        public var spansPerWindow: Int
        public var maxBreakSeconds: Double
        /// Share of the runtime the episode's ad time may reach.
        public var budgetFraction: Double
        public var budgetFloorSeconds: Double
        /// Longest evidence quote accepted, in normalized words.
        public var evidenceWords: Int

        enum CodingKeys: String, CodingKey {
            case spansPerWindow = "spans_per_window"
            case maxBreakSeconds = "max_break_seconds"
            case budgetFraction = "budget_fraction"
            case budgetFloorSeconds = "budget_floor_seconds"
            case evidenceWords = "evidence_words"
        }
    }

    public struct Repair: Sendable, Equatable, Decodable {
        /// Corrective re-requests allowed per window.
        public var attempts: Int
        public var feedbackBytes: Int

        enum CodingKeys: String, CodingKey {
            case attempts
            case feedbackBytes = "feedback_bytes"
        }
    }

    public var policy: String
    public var revision: String
    /// System instruction text, byte for byte.
    public var prompt: String
    public var responseSchema: AnalysisPolicyJSON
    public var window: Window
    public var limits: Limits
    public var repair: Repair
    /// At most one entry per provider: that provider's default.
    public var qualifiedModels: [AnalysisModelEntry]
    public var additionalModels: [AnalysisModelEntry]
    /// Entries of providers this build does not know; they still count toward the entry bound.
    var skippedModelCount: Int

    enum CodingKeys: String, CodingKey {
        case policy
        case revision
        case prompt
        case responseSchema = "response_schema"
        case window
        case limits
        case repair
        case qualifiedModels = "qualified_models"
        case additionalModels = "additional_models"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(String.self, forKey: .policy)
        revision = try container.decode(String.self, forKey: .revision)
        prompt = try container.decode(String.self, forKey: .prompt)
        responseSchema = try container.decode(AnalysisPolicyJSON.self, forKey: .responseSchema)
        window = try container.decode(Window.self, forKey: .window)
        limits = try container.decode(Limits.self, forKey: .limits)
        repair = try container.decode(Repair.self, forKey: .repair)
        let qualified = try container.decode(KnownProviderList<AnalysisModelEntry>.self, forKey: .qualifiedModels)
        let additional = container.contains(.additionalModels)
            ? try container.decode(KnownProviderList<AnalysisModelEntry>.self, forKey: .additionalModels)
            : nil
        qualifiedModels = qualified.items
        additionalModels = additional?.items ?? []
        skippedModelCount = qualified.skippedCount + (additional?.skippedCount ?? 0)
    }
}
