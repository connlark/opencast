import Foundation

protocol AppleSpeechAssetProviding: Sendable {
    var isTranscriberAvailable: Bool { get }
    var maximumReservedLocales: Int { get }
    func supportedLocaleIdentifier(equivalentTo languageCode: String) async -> String?
    func installedLocaleIdentifiers() async -> [String]
    func status(forLocaleIdentifier localeIdentifier: String) async -> AppleSpeechAssetLocaleStatus
    func installAssets(
        forLocaleIdentifier localeIdentifier: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
    func reservedLocaleIdentifiers() async -> [String]
    @discardableResult
    func reserveLocale(_ localeIdentifier: String) async throws -> Bool
    @discardableResult
    func releaseLocale(_ localeIdentifier: String) async -> Bool
}
