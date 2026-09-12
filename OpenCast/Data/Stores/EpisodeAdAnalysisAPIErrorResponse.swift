import Foundation
import OpenCastTranscription

nonisolated struct EpisodeAdAnalysisAPIErrorResponse: Decodable, Sendable {
    var error: String
    var detail: String?
    var failure: OpenCastAdAnalysisFailure?
    enum CodingKeys: String, CodingKey { case error, detail, failure }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        error = try values.decode(String.self, forKey: .error)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        failure = try? values.decodeIfPresent(OpenCastAdAnalysisFailure.self, forKey: .failure)
    }
}
