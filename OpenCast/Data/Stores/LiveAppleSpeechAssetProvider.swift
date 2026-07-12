import Foundation
import Speech

struct LiveAppleSpeechAssetProvider: AppleSpeechAssetProviding {
    nonisolated var isTranscriberAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    nonisolated var maximumReservedLocales: Int {
        AssetInventory.maximumReservedLocales
    }

    nonisolated func supportedLocaleIdentifier(equivalentTo languageCode: String) async -> String? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode))?.identifier
    }

    nonisolated func installedLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
    }

    nonisolated func status(forLocaleIdentifier localeIdentifier: String) async -> AppleSpeechAssetLocaleStatus {
        switch await AssetInventory.status(forModules: [Self.transcriber(for: localeIdentifier)]) {
        case .unsupported:
            .unsupported
        case .supported:
            .supported
        case .downloading:
            .downloading
        case .installed:
            .installed
        @unknown default:
            .unsupported
        }
    }

    nonisolated func installAssets(
        forLocaleIdentifier localeIdentifier: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let transcriber = Self.transcriber(for: localeIdentifier)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }

        let progress = request.progress
        let poller = Task {
            var lastReportedFraction = -1.0
            while !Task.isCancelled {
                let fraction = progress.fractionCompleted
                if fraction != lastReportedFraction {
                    lastReportedFraction = fraction
                    onProgress(fraction)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer {
            poller.cancel()
        }

        try await request.downloadAndInstall()
        onProgress(1)
    }

    nonisolated func reservedLocaleIdentifiers() async -> [String] {
        await AssetInventory.reservedLocales.map(\.identifier).sorted()
    }

    @discardableResult
    nonisolated func reserveLocale(_ localeIdentifier: String) async throws -> Bool {
        try await AssetInventory.reserve(locale: Locale(identifier: localeIdentifier))
    }

    @discardableResult
    nonisolated func releaseLocale(_ localeIdentifier: String) async -> Bool {
        await AssetInventory.release(reservedLocale: Locale(identifier: localeIdentifier))
    }

    private nonisolated static func transcriber(for localeIdentifier: String) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: localeIdentifier),
            preset: .timeIndexedProgressiveTranscription
        )
    }
}
