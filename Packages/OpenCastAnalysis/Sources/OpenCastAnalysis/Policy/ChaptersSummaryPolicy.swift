/// Chapters & Summary settings from the policy bundle. One call per episode;
/// long transcripts are coalesced into units before the call.
public struct ChaptersSummaryPolicy: Sendable, Equatable, Decodable {
    public struct Coalescing: Sendable, Equatable, Decodable {
        /// Transcripts with more segments than this are coalesced.
        public var aboveSegments: Int
        /// A unit closes once it spans at least this long.
        public var unitSeconds: Double
        /// A unit closes before its joined text would pass this many characters.
        public var unitChars: Int
        /// A silence at least this long always starts a new unit.
        public var gapSeconds: Double
        /// More units than this fails the request.
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
        /// One further chapter allowed per this many seconds of audio.
        public var secondsPerChapter: Double

        enum CodingKeys: String, CodingKey {
            case min
            case secondsPerChapter = "seconds_per_chapter"
        }
    }

    /// Policy name rendered into the prompt header.
    public var policy: String
    public var revision: String
    /// The rules text. The pipeline appends the header and segment lines after
    /// it exactly as the worker renders its prompt.
    public var prompt: String
    public var responseSchema: AnalysisPolicyJSON
    public var coalescing: Coalescing
    public var chapterCap: ChapterCap
    /// One entry per provider at most; a provider without an entry is hidden
    /// for this feature.
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
