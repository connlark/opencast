import Foundation

public struct AppleSpeechAssetStatus: Codable, Sendable, Equatable {
    public var requestedLocaleIdentifier: String
    public var resolvedLocaleIdentifier: String?
    public var transcriberAvailable: Bool
    public var assetInventoryStatus: String?
    public var installedLocaleIdentifiers: [String]

    public init(
        requestedLocaleIdentifier: String,
        resolvedLocaleIdentifier: String?,
        transcriberAvailable: Bool,
        assetInventoryStatus: String?,
        installedLocaleIdentifiers: [String]
    ) {
        self.requestedLocaleIdentifier = requestedLocaleIdentifier
        self.resolvedLocaleIdentifier = resolvedLocaleIdentifier
        self.transcriberAvailable = transcriberAvailable
        self.assetInventoryStatus = assetInventoryStatus
        self.installedLocaleIdentifiers = installedLocaleIdentifiers
    }
}
