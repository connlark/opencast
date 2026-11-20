import Foundation

nonisolated enum AnalysisJobPollOutcome<Response: Decodable & Sendable & Equatable>: Decodable, Sendable, Equatable {
    case running(pollAfter: TimeInterval)
    case completed(Response)

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnalysisJobEnvelopeCodingKeys.self)
        guard container.contains(.jobID) else {
            self = .completed(try Response(from: decoder))
            return
        }

        _ = try container.decode(String.self, forKey: .jobID)
        let state = try container.decode(String.self, forKey: .state)
        guard state == "running" else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Unknown analysis job state: \(state)"
            )
        }
        self = .running(
            pollAfter: try container.decodeIfPresent(TimeInterval.self, forKey: .pollAfter) ?? 5
        )
    }
}
