import Foundation

/// The signed analysis policy document: prompts, schemas, model entries,
/// timeouts and limits for ad detection and Chapters & Summary. Decoding
/// alone proves nothing; `AnalysisPolicyValidator` verifies the signature
/// and the app's hard bounds before a bundle is used.
public struct AnalysisPolicyBundle: Sendable, Equatable, Decodable {
    public struct Features: Sendable, Equatable, Decodable {
        public var adDetection: AdDetectionPolicy
        public var chaptersSummary: ChaptersSummaryPolicy

        enum CodingKeys: String, CodingKey {
            case adDetection = "ad_detection"
            case chaptersSummary = "chapters_summary"
        }
    }

    /// Document format. This build reads format 1 only.
    public var schemaVersion: Int
    /// Monotonic content version; the app never moves to a lower one.
    public var bundleVersion: Int
    public var generatedAt: Date
    /// Lowest `CFBundleVersion` that may use this bundle.
    public var minAppBuild: Int
    public var features: Features
    /// Wire facts for the providers this build knows; others are ignored.
    public var providers: [AnalysisProvider: AnalysisProviderEndpoint]
    public var trial: AnalysisTrialPolicy
    public var notice: AnalysisNoticePolicy?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bundleVersion = "bundle_version"
        case generatedAt = "generated_at"
        case minAppBuild = "min_app_build"
        case features
        case providers
        case trial
        case notice
    }

    private struct ProviderKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        bundleVersion = try container.decode(Int.self, forKey: .bundleVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        minAppBuild = try container.decode(Int.self, forKey: .minAppBuild)
        features = try container.decode(Features.self, forKey: .features)
        let providerContainer = try container.nestedContainer(keyedBy: ProviderKey.self, forKey: .providers)
        var providers: [AnalysisProvider: AnalysisProviderEndpoint] = [:]
        for provider in AnalysisProvider.allCases {
            providers[provider] = try providerContainer.decodeIfPresent(
                AnalysisProviderEndpoint.self,
                forKey: ProviderKey(stringValue: provider.rawValue)
            )
        }
        self.providers = providers
        trial = try container.decode(AnalysisTrialPolicy.self, forKey: .trial)
        notice = try container.decodeIfPresent(AnalysisNoticePolicy.self, forKey: .notice)
    }

    /// Decodes bundle bytes. Timestamps must be canonical UTC
    /// (`AnalysisPolicyTimestamp`), the same rule the generator enforces.
    public static func decode(_ data: Data) throws -> AnalysisPolicyBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = AnalysisPolicyTimestamp.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "not a canonical UTC timestamp"
                )
            }
            return date
        }
        return try decoder.decode(AnalysisPolicyBundle.self, from: data)
    }
}
