import Foundation

/// Display facts only: the trial worker enforces the real limits.
public struct AnalysisTrialPolicy: Sendable, Equatable, Decodable {
    public var endpoint: URL
    /// Before this instant every install is served without a unit count.
    public var startsAt: Date
    public var lifetimeUnits: Int
    public var modelID: String

    enum CodingKeys: String, CodingKey {
        case endpoint
        case startsAt = "starts_at"
        case lifetimeUnits = "lifetime_units"
        case modelID = "model"
    }
}

public struct AnalysisNoticePolicy: Sendable, Equatable, Decodable {
    public var startsAt: Date

    enum CodingKeys: String, CodingKey {
        case startsAt = "starts_at"
    }
}
