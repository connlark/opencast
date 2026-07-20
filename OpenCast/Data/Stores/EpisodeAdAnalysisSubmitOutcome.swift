import Foundation

nonisolated enum EpisodeAdAnalysisSubmitOutcome: Decodable, Sendable, Equatable {
    case completed(EpisodeAdAnalysisAPIResponse)
    case accepted(jobID: String, pollAfter: TimeInterval)

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.jobID) else {
            self = .completed(try EpisodeAdAnalysisAPIResponse(from: decoder))
            return
        }

        let jobID = try container.decode(String.self, forKey: .jobID)
        let state = try container.decode(String.self, forKey: .state)
        guard state == "running" else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Unknown ad-analysis job state: \(state)"
            )
        }
        self = .accepted(
            jobID: jobID,
            pollAfter: try container.decodeIfPresent(TimeInterval.self, forKey: .pollAfter) ?? 5
        )
    }

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state
        case pollAfter = "poll_after_seconds"
    }
}
