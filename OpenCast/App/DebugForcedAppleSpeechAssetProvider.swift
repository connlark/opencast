#if DEBUG
import Foundation

/// DEBUG-only provider so simulators (which report Apple Speech unsupported)
/// can render the Apple-branch settings/onboarding surfaces in UI tests and
/// screenshots. Never performs real installs.
struct DebugForcedAppleSpeechAssetProvider: AppleSpeechAssetProviding {
    enum ForcedState: String {
        case installed
        case installable
        case unavailable
    }

    static let argument = "--opencast-apple-speech-fake-assets"
    static let environmentKey = "OPENCAST_APPLE_SPEECH_FAKE_ASSETS"

    let forcedState: ForcedState

    static var requestedProvider: DebugForcedAppleSpeechAssetProvider? {
        let processInfo = ProcessInfo.processInfo
        var value = processInfo.environment[environmentKey]
        for (index, argument) in processInfo.arguments.enumerated() {
            if argument.hasPrefix("\(Self.argument)=") {
                value = String(argument.dropFirst(Self.argument.count + 1))
            } else if argument == Self.argument, processInfo.arguments.indices.contains(index + 1) {
                value = processInfo.arguments[index + 1]
            }
        }

        guard let value,
              let forcedState = ForcedState(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else {
            return nil
        }
        return DebugForcedAppleSpeechAssetProvider(forcedState: forcedState)
    }

    var isTranscriberAvailable: Bool {
        forcedState != .unavailable
    }

    var maximumReservedLocales: Int {
        3
    }

    func supportedLocaleIdentifier(equivalentTo languageCode: String) async -> String? {
        forcedState == .unavailable ? nil : "en_US"
    }

    func installedLocaleIdentifiers() async -> [String] {
        forcedState == .installed ? ["en_US"] : []
    }

    func status(forLocaleIdentifier localeIdentifier: String) async -> AppleSpeechAssetLocaleStatus {
        switch forcedState {
        case .installed:
            .installed
        case .installable:
            .supported
        case .unavailable:
            .unsupported
        }
    }

    func installAssets(
        forLocaleIdentifier localeIdentifier: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        onProgress(0.5)
        try? await Task.sleep(for: .milliseconds(150))
        onProgress(1)
    }

    func reservedLocaleIdentifiers() async -> [String] {
        []
    }

    @discardableResult
    func reserveLocale(_ localeIdentifier: String) async throws -> Bool {
        true
    }

    @discardableResult
    func releaseLocale(_ localeIdentifier: String) async -> Bool {
        false
    }
}
#endif
