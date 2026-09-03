import Foundation

/// A worker's answer to a job submit: the finished response when it ran
/// synchronously, or the accepted job to poll. Shared by the ad and
/// transcript analysis clients, whose workers speak the same job envelope.
nonisolated enum AnalysisJobSubmitOutcome<Response: Decodable & Sendable & Equatable>: Decodable, Sendable, Equatable {
    case completed(Response)
    case accepted(jobID: String, pollAfter: TimeInterval)

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnalysisJobEnvelopeCodingKeys.self)
        guard container.contains(.jobID) else {
            self = .completed(try Response(from: decoder))
            return
        }

        let jobID = try container.decode(String.self, forKey: .jobID)
        let state = try container.decode(String.self, forKey: .state)
        guard state == "running" else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Unknown analysis job state: \(state)"
            )
        }
        self = .accepted(
            jobID: jobID,
            pollAfter: try container.decodeIfPresent(TimeInterval.self, forKey: .pollAfter) ?? 5
        )
    }
}
