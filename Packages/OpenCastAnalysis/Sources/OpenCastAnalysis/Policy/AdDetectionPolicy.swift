/// Ad-detection settings from the policy bundle. Validator logic is not here:
/// these are the parameters it runs with, each inside the app's hard bounds
/// (`AnalysisPolicyClamp`).
public struct AdDetectionPolicy: Sendable, Equatable, Decodable {
    public struct Window: Sendable, Equatable, Decodable {
        /// Segments per model request.
        public var segments: Int
        /// Segments shared by neighbouring windows.
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
        /// Spans one window's answer may hold before it fails closed.
        public var spansPerWindow: Int
        /// Longest single break accepted.
        public var maxBreakSeconds: Double
        /// Share of the runtime the episode's ad time may reach.
        public var budgetFraction: Double
        /// Ad time always allowed regardless of runtime.
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
        /// Largest repair feedback block, in bytes.
        public var feedbackBytes: Int

        enum CodingKeys: String, CodingKey {
            case attempts
            case feedbackBytes = "feedback_bytes"
        }
    }

    /// Policy name rendered into the request's user JSON.
    public var policy: String
    /// Serving revision of the prompt, validator and model settings.
    public var revision: String
    /// System instruction text, byte for byte.
    public var prompt: String
    /// Structured-output schema sent with every request.
    public var responseSchema: AnalysisPolicyJSON
    public var window: Window
    public var limits: Limits
    public var repair: Repair
    /// One entry per provider at most, each qualified on the golden suite.
    public var qualifiedModels: [AnalysisModelEntry]

    enum CodingKeys: String, CodingKey {
        case policy
        case revision
        case prompt
        case responseSchema = "response_schema"
        case window
        case limits
        case repair
        case qualifiedModels = "qualified_models"
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
        qualifiedModels = try container.decode(KnownProviderModelEntries.self, forKey: .qualifiedModels).entries
    }
}
