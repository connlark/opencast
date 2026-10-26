import Foundation

/// Display facts about the opencast-funded trial. The trial worker enforces
/// the real limits; the app only shows them and picks the route.
public struct AnalysisTrialPolicy: Sendable, Equatable, Decodable {
    public var endpoint: URL
    /// Before this instant every install is served without a unit count.
    public var startsAt: Date
    public var lifetimeUnits: Int
    /// The Google ad-detection entry the trial runs on.
    public var modelID: String

    enum CodingKeys: String, CodingKey {
        case endpoint
        case startsAt = "starts_at"
        case lifetimeUnits = "lifetime_units"
        case modelID = "model"
    }
}

/// When the in-app notice about provider keys starts. Absent means no notice.
public struct AnalysisNoticePolicy: Sendable, Equatable, Decodable {
    public var startsAt: Date

    enum CodingKeys: String, CodingKey {
        case startsAt = "starts_at"
    }
}
