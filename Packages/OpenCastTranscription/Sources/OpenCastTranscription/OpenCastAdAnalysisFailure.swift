/// Content-free failure contract shared by direct and chained ad analysis.
public struct OpenCastAdAnalysisFailure: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable {
        case capacity
        case transientTransport = "transient_transport"
        case interruptedJob = "interrupted_job"
        case validationExhausted = "validation_exhausted"
        case unsupportedInput = "unsupported_input"
    }

    public enum RetryDisposition: String, Codable, Sendable {
        case afterCapacity = "after_capacity"
        case boundedRetry = "bounded_retry"
        case explicitRetry = "explicit_retry"
        case changedInput = "changed_input"
    }

    public var category: Category
    public var retryDisposition: RetryDisposition
    public var policyRevision: String?

    public init(category: Category, retryDisposition: RetryDisposition, policyRevision: String? = nil) {
        self.category = category
        self.retryDisposition = retryDisposition
        self.policyRevision = policyRevision
    }

    public var suppressesAutomaticReplay: Bool {
        category == .validationExhausted || category == .unsupportedInput
    }

    enum CodingKeys: String, CodingKey {
        case category
        case retryDisposition = "retry_disposition"
        case policyRevision = "policy_revision"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        category = try values.decode(Category.self, forKey: .category)
        retryDisposition = try values.decode(RetryDisposition.self, forKey: .retryDisposition)
        let revision = try values.decodeIfPresent(String.self, forKey: .policyRevision)
        guard revision.map({ $0.utf8.count <= 96 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .policyRevision, in: values, debugDescription: "Invalid policy revision")
        }
        policyRevision = revision
    }
}
