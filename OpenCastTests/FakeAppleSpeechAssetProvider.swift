import Foundation
@testable import OpenCast

final class FakeAppleSpeechAssetProvider: AppleSpeechAssetProviding, @unchecked Sendable {
    var isTranscriberAvailable: Bool
    var maximumReservedLocales: Int
    /// Requested language code (lowercased) → resolved locale identifier.
    var resolvedLocalesByLanguage: [String: String]
    var statusesByLocaleIdentifier: [String: AppleSpeechAssetLocaleStatus]
    var reserved: [String]
    var installError: Error?
    var installProgressFractions: [Double]
    /// When set, `installAssets` waits here before finishing so tests can
    /// observe the mid-install state.
    var installGate: AsyncStream<Void>.Continuation?
    private var installGateStream: AsyncStream<Void>?

    private(set) var installRequests: [String] = []
    private(set) var reserveRequests: [String] = []
    private(set) var releasedLocaleIdentifiers: [String] = []

    init(
        isTranscriberAvailable: Bool = true,
        maximumReservedLocales: Int = 3,
        resolvedLocalesByLanguage: [String: String] = ["en-us": "en_US"],
        statusesByLocaleIdentifier: [String: AppleSpeechAssetLocaleStatus] = ["en_US": .installed],
        reserved: [String] = [],
        installProgressFractions: [Double] = [0.5]
    ) {
        self.isTranscriberAvailable = isTranscriberAvailable
        self.maximumReservedLocales = maximumReservedLocales
        self.resolvedLocalesByLanguage = resolvedLocalesByLanguage
        self.statusesByLocaleIdentifier = statusesByLocaleIdentifier
        self.reserved = reserved
        self.installProgressFractions = installProgressFractions
    }

    func makeInstallGate() {
        var continuation: AsyncStream<Void>.Continuation?
        let stream = AsyncStream<Void> { continuation = $0 }
        installGateStream = stream
        installGate = continuation
    }

    func supportedLocaleIdentifier(equivalentTo languageCode: String) async -> String? {
        resolvedLocalesByLanguage[languageCode.lowercased()]
    }

    func installedLocaleIdentifiers() async -> [String] {
        statusesByLocaleIdentifier
            .filter { $0.value == .installed }
            .keys
            .sorted()
    }

    func status(forLocaleIdentifier localeIdentifier: String) async -> AppleSpeechAssetLocaleStatus {
        statusesByLocaleIdentifier[localeIdentifier] ?? .unsupported
    }

    func installAssets(
        forLocaleIdentifier localeIdentifier: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        installRequests.append(localeIdentifier)
        for fraction in installProgressFractions {
            onProgress(fraction)
        }
        if let installGateStream {
            for await _ in installGateStream {
                break
            }
        }
        if let installError {
            throw installError
        }
        statusesByLocaleIdentifier[localeIdentifier] = .installed
        onProgress(1)
    }

    func reservedLocaleIdentifiers() async -> [String] {
        reserved.sorted()
    }

    @discardableResult
    func reserveLocale(_ localeIdentifier: String) async throws -> Bool {
        reserveRequests.append(localeIdentifier)
        guard !reserved.contains(localeIdentifier) else {
            return true
        }
        guard reserved.count < maximumReservedLocales else {
            throw FakeAppleSpeechAssetProviderError.reservationCapReached
        }
        reserved.append(localeIdentifier)
        return true
    }

    @discardableResult
    func releaseLocale(_ localeIdentifier: String) async -> Bool {
        releasedLocaleIdentifiers.append(localeIdentifier)
        guard let index = reserved.firstIndex(of: localeIdentifier) else {
            return false
        }
        reserved.remove(at: index)
        return true
    }
}

enum FakeAppleSpeechAssetProviderError: Error {
    case reservationCapReached
    case installFailed
}
