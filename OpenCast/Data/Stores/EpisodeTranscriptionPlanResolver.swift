import Foundation
import OpenCastTranscription

struct EpisodeTranscriptionPlanResolver {
    static let fallbackLanguageCode = "en-US"
    static let whisperRunLanguageCode = "en"

    let transcriptionModels: TranscriptionModelStore
    let appleSpeechAssets: AppleSpeechAssetStore
    /// Whisper tiny's window checkpoints survive the system revoking a continued-processing task;
    /// Apple Speech restarts from zero.
    var prefersRevocationDurableEngine = false

    func resolve(
        requestedEngine: AdFreePassTranscriptionEngine,
        podcastLanguageCode: String?
    ) async throws -> EpisodeTranscriptionPlan {
        switch requestedEngine {
        case .productDefault:
            return try await resolveProductDefault(podcastLanguageCode: podcastLanguageCode)
        case .selectedWhisperModel:
            guard let modelSummary = transcriptionModels.installedSummary else {
                throw EpisodeTranscriptionError.missingSpeechModel
            }
            return whisperPlan(
                summary: modelSummary,
                languageCode: Self.whisperRunLanguageCode,
                isEngineStrict: true
            )
        case .whisperTiny:
            let modelSummary = try transcriptionModels.installedSummary(for: .fastTinyEnglish)
            return whisperPlan(
                summary: modelSummary,
                languageCode: Self.whisperRunLanguageCode,
                isEngineStrict: true
            )
        case .appleSpeech:
            return try await strictApplePlan(podcastLanguageCode: podcastLanguageCode)
        }
    }

    private func resolveProductDefault(
        podcastLanguageCode: String?
    ) async throws -> EpisodeTranscriptionPlan {
        let languageCode = podcastLanguageCode ?? Self.fallbackLanguageCode

        if prefersRevocationDurableEngine {
            guard let tinySummary = try? transcriptionModels.installedSummary(for: .fastTinyEnglish) else {
                throw EpisodeTranscriptionError.missingSpeechModel
            }
            AdFreePassBackgroundRunLog.record(
                "engine resolution durable whisperTiny language=\(languageCode)"
            )
            return whisperPlan(
                summary: tinySummary,
                languageCode: languageCode,
                isEngineStrict: false
            )
        }

        if appleSpeechAssets.isTranscriberAvailable {
            do {
                let localeIdentifier = try await appleSpeechAssets.ensureInstalledAssets(
                    forLanguageCode: languageCode
                )
                return applePlan(
                    localeIdentifier: localeIdentifier,
                    languageCode: languageCode,
                    isEngineStrict: false
                )
            } catch {
                AdFreePassBackgroundRunLog.record(
                    "engine resolution apple failed language=\(languageCode) fallback=whisperTiny error=\(error.localizedDescription)"
                )
            }
        } else {
            AdFreePassBackgroundRunLog.record(
                "engine resolution apple transcriber unavailable fallback=whisperTiny"
            )
        }

        guard let tinySummary = try? transcriptionModels.installedSummary(for: .fastTinyEnglish) else {
            throw EpisodeTranscriptionError.missingSpeechModel
        }

        return whisperPlan(
            summary: tinySummary,
            languageCode: languageCode,
            isEngineStrict: false
        )
    }

    private func strictApplePlan(podcastLanguageCode: String?) async throws -> EpisodeTranscriptionPlan {
        let languageCode = podcastLanguageCode ?? Self.fallbackLanguageCode
        guard appleSpeechAssets.isTranscriberAvailable else {
            throw AppleSpeechTranscriptionError.transcriberUnavailable
        }
        let (localeIdentifier, status) = await appleSpeechAssets.status(forLanguageCode: languageCode)
        guard let localeIdentifier else {
            throw AppleSpeechTranscriptionError.unsupportedLocale(languageCode)
        }
        guard status == .installed else {
            throw AppleSpeechTranscriptionError.assetsNotInstalled(
                localeIdentifier: localeIdentifier,
                status: status?.rawValue ?? "unknown"
            )
        }
        appleSpeechAssets.recordLocaleUsed(localeIdentifier)
        return applePlan(
            localeIdentifier: localeIdentifier,
            languageCode: languageCode,
            isEngineStrict: true
        )
    }

    private func applePlan(
        localeIdentifier: String,
        languageCode: String,
        isEngineStrict: Bool
    ) -> EpisodeTranscriptionPlan {
        EpisodeTranscriptionPlan(
            runEngine: .appleSpeech,
            modelIdentity: Self.appleModelIdentity(localeIdentifier: localeIdentifier),
            languageCode: languageCode,
            runLanguageCode: languageCode,
            isEngineStrict: isEngineStrict
        )
    }

    private func whisperPlan(
        summary: OpenCastWhisperModelInstalledSummary,
        languageCode: String,
        isEngineStrict: Bool
    ) -> EpisodeTranscriptionPlan {
        EpisodeTranscriptionPlan(
            runEngine: .whisper,
            modelIdentity: EpisodeTranscriptionModelIdentity(summary: summary),
            languageCode: languageCode,
            runLanguageCode: Self.whisperRunLanguageCode,
            isEngineStrict: isEngineStrict
        )
    }

    static func appleModelIdentity(localeIdentifier: String) -> EpisodeTranscriptionModelIdentity {
        EpisodeTranscriptionModelIdentity(
            modelIdentifier: AppleSpeechTranscriptionService.modelIdentifier(
                localeIdentifier: localeIdentifier
            ),
            version: ProcessInfo.processInfo.operatingSystemVersionString,
            treeSHA256: "asset-status-installed-\(localeIdentifier)"
        )
    }
}
