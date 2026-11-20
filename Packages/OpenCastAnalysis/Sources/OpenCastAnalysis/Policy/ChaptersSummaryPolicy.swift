public struct ChaptersSummaryPolicy: Sendable, Equatable, Decodable {
    public struct Coalescing: Sendable, Equatable, Decodable {
        public var aboveSegments: Int
        /// A unit closes once it spans at least this long.
        public var unitSeconds: Double
        /// A unit closes before its joined text would pass this many characters.
        public var unitChars: Int
        /// A silence longer than this starts a new unit.
        public var gapSeconds: Double
        public var maxUnits: Int

        enum CodingKeys: String, CodingKey {
            case aboveSegments = "above_segments"
            case unitSeconds = "unit_seconds"
            case unitChars = "unit_chars"
            case gapSeconds = "gap_seconds"
            case maxUnits = "max_units"
        }
    }

    public struct ChapterCap: Sendable, Equatable, Decodable {
        /// Chapters always allowed, however short the episode.
        public var min: Int
        /// The cap is one chapter per this many seconds of audio, never below `min`.
        public var secondsPerChapter: Double

        enum CodingKeys: String, CodingKey {
            case min
            case secondsPerChapter = "seconds_per_chapter"
        }
    }

    public var policy: String
    public var revision: String
    public var prompt: String
    public var responseSchema: AnalysisPolicyJSON
    public var coalescing: Coalescing
    public var chapterCap: ChapterCap
    /// At most one entry per provider.
    public var allowedModels: [AnalysisModelEntry]

    enum CodingKeys: String, CodingKey {
        case policy
        case revision
        case prompt
        case responseSchema = "response_schema"
        case coalescing
        case chapterCap = "chapter_cap"
        case allowedModels = "allowed_models"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(String.self, forKey: .policy)
        revision = try container.decode(String.self, forKey: .revision)
        prompt = try container.decode(String.self, forKey: .prompt)
        responseSchema = try container.decode(AnalysisPolicyJSON.self, forKey: .responseSchema)
        coalescing = try container.decode(Coalescing.self, forKey: .coalescing)
        chapterCap = try container.decode(ChapterCap.self, forKey: .chapterCap)
        allowedModels = try container.decode(KnownProviderModelEntries.self, forKey: .allowedModels).entries
    }
}
