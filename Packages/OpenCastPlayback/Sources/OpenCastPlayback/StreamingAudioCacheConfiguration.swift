import Foundation

public nonisolated struct StreamingAudioCacheConfiguration: Sendable, Equatable {
    public static let defaultByteBudget: Int64 = 1_024 * 1_024 * 1_024
    public static let disabled = StreamingAudioCacheConfiguration(
        isEnabled: false,
        directory: nil,
        byteBudget: defaultByteBudget
    )

    public var isEnabled: Bool
    public var directory: URL?
    public var byteBudget: Int64

    public init(
        isEnabled: Bool = false,
        directory: URL? = nil,
        byteBudget: Int64 = defaultByteBudget
    ) {
        self.isEnabled = isEnabled
        self.directory = directory
        self.byteBudget = byteBudget
    }
}
