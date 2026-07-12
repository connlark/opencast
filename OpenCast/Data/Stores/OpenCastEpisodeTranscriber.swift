import Foundation
import OpenCastTranscription

struct OpenCastEpisodeTranscriber: EpisodeTranscribing {
    let injectedService: OpenCastTranscriptionService?
    private let currentServiceTracker = CurrentTranscriptionServiceTracker()

    init(service: OpenCastTranscriptionService? = nil) {
        injectedService = service
    }

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var serviceToken: UUID?
                do {
                    let preparedStream = try await makeTranscriptionStream(for: request)
                    serviceToken = preparedStream.serviceToken
                    try await forward(preparedStream.stream, to: continuation)
                    await unload(serviceToken)
                    continuation.finish()
                } catch {
                    await unload(serviceToken)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func unload() async {
        if let injectedService {
            await injectedService.unload()
        } else {
            await currentServiceTracker.unloadCurrentService()
        }
    }

    private func makeTranscriptionStream(
        for request: EpisodeTranscriptionRunRequest
    ) async throws -> PreparedTranscriptionStream {
        switch request.engine {
        case .whisper:
            let service = try makeWhisperService(for: request)
            let serviceToken = track(service)
            let stream = await service.transcribe(longFormRequest(from: request))
            return PreparedTranscriptionStream(stream: stream, serviceToken: serviceToken)
        case .appleSpeech:
            let service = AppleSpeechTranscriptionService(
                requiresInstalledAssets: true,
                allowsAssetInstallation: false
            )
            let serviceToken = track(service)
            AdFreePassBackgroundRunLog.record("compute selected profile=appleSpeech strictInstalledAssets=true")
            let stream = service.transcribe(longFormRequest(from: request))
            return PreparedTranscriptionStream(stream: stream, serviceToken: serviceToken)
        }
    }

    private func makeWhisperService(for request: EpisodeTranscriptionRunRequest) throws -> OpenCastTranscriptionService {
        if let injectedService {
            return injectedService
        }

        guard let model = OpenCastWhisperModel(rawValue: request.modelIdentifier) else {
            throw OpenCastTranscriptionError.unsupportedModelIdentifier(request.modelIdentifier)
        }

        let computeProfile = Self.computeProfileForNewService(requestedProfile: request.computeProfile)
        AdFreePassBackgroundRunLog.record("compute selected profile=\(computeProfile.logDescription)")
        return OpenCastTranscriptionService(
            modelLocator: DownloadedWhisperModelLocator(
                model: model,
                version: request.modelVersion
            ),
            computeProfile: computeProfile
        )
    }

    private func longFormRequest(from request: EpisodeTranscriptionRunRequest) -> OpenCastLongFormTranscriptionRequest {
        OpenCastLongFormTranscriptionRequest(
            audioFileURL: request.audioFileURL,
            languageCode: request.languageCode,
            resumeStart: request.resumeStart,
            sourceAudioURL: request.sourceAudioURL,
            sourceFileByteCount: request.sourceFileByteCount,
            sourceFileSHA256: request.sourceFileSHA256,
            modelIdentifier: request.modelIdentifier,
            modelVersion: request.modelVersion,
            modelTreeSHA256: request.modelTreeSHA256
        )
    }

    private func forward(
        _ stream: AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error>,
        to continuation: AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>.Continuation
    ) async throws {
        for try await event in stream {
            switch event {
            case .progress(let progress):
                continuation.yield(.progress(EpisodeTranscriptionProgress(
                    audioDuration: progress.audioDuration,
                    completedDuration: progress.completedDuration,
                    checkpointCount: progress.checkpointCount,
                    currentWindowIndex: progress.currentWindowIndex,
                    currentText: progress.currentText
                )))
            case .checkpoint(let checkpoint):
                continuation.yield(.checkpoint(checkpoint))
            case .finished(let result):
                continuation.yield(.finished(result))
            }
        }
    }

    private static func computeProfileForNewService(
        requestedProfile: OpenCastTranscriptionComputeProfile
    ) -> OpenCastTranscriptionComputeProfile {
        #if DEBUG
        if let requestedProfile = debugComputeProfileOverride() {
            return requestedProfile
        }
        #endif
        return resolvedComputeProfile(
            requestedProfile: requestedProfile,
            supportsBackgroundGPU: BGTaskSchedulerAdFreePassScheduler().supportsGPUResources
        )
    }

    /// Decision 16: devices granted background GPU get WhisperKit-default
    /// compute back; everything else keeps the step-5 CPU+ANE pin. Explicit
    /// profiles (the cpuOnly fallback/sticky rung) are never upgraded.
    static func resolvedComputeProfile(
        requestedProfile: OpenCastTranscriptionComputeProfile,
        supportsBackgroundGPU: Bool
    ) -> OpenCastTranscriptionComputeProfile {
        guard requestedProfile == .backgroundSafe, supportsBackgroundGPU else {
            return requestedProfile
        }

        return .whisperKitDefault
    }

    #if DEBUG
    private static func debugComputeProfileOverride() -> OpenCastTranscriptionComputeProfile? {
        let processInfo = ProcessInfo.processInfo
        let environmentValue = processInfo.environment["OPENCAST_ADFREEPASS_COMPUTE"]
        let argumentValue = debugComputeProfileArgumentValue(from: processInfo.arguments)
        let value = argumentValue ?? environmentValue
        guard let value else {
            return nil
        }

        let normalizedValue = value == "cpuAndNE" ? OpenCastTranscriptionComputeProfile.cpuAndNeuralEngine.rawValue : value
        guard let profile = OpenCastTranscriptionComputeProfile(rawValue: normalizedValue) else {
            AdFreePassBackgroundRunLog.record("compute override ignored value=\(value)")
            return nil
        }
        return profile
    }

    private static func debugComputeProfileArgumentValue(from arguments: [String]) -> String? {
        let flag = "--adfreepass-compute"
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("\(flag)=") {
                return String(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
        }
        return nil
    }
    #endif

    private func track(_ service: OpenCastTranscriptionService) -> UUID? {
        guard injectedService == nil else {
            return nil
        }

        return currentServiceTracker.setCurrentUnload {
            await service.unload()
        }
    }

    private func track(_ service: AppleSpeechTranscriptionService) -> UUID? {
        currentServiceTracker.setCurrentUnload {
            await service.unload()
        }
    }

    private func unload(_ serviceToken: UUID?) async {
        await currentServiceTracker.unload(serviceToken)
    }

    private struct PreparedTranscriptionStream {
        var stream: AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error>
        var serviceToken: UUID?
    }
}

private final class CurrentTranscriptionServiceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var currentService: CurrentService?

    func setCurrentUnload(_ unload: @escaping @Sendable () async -> Void) -> UUID {
        let token = UUID()
        lock.withLock {
            currentService = CurrentService(token: token, unload: unload)
        }
        return token
    }

    func unload(_ token: UUID?) async {
        guard let token else {
            return
        }

        let service = lock.withLock {
            currentService?.token == token ? currentService : nil
        }
        guard let service else {
            return
        }

        await service.unload()
        lock.withLock {
            if currentService?.token == token {
                currentService = nil
            }
        }
    }

    func unloadCurrentService() async {
        let service = lock.withLock {
            currentService
        }

        guard let service else {
            return
        }

        await service.unload()
        lock.withLock {
            if currentService?.token == service.token {
                currentService = nil
            }
        }
    }

    private struct CurrentService {
        var token: UUID
        var unload: @Sendable () async -> Void
    }
}

private extension NSLock {
    func withLock<Result>(_ work: () -> Result) -> Result {
        lock()
        defer {
            unlock()
        }
        return work()
    }
}
