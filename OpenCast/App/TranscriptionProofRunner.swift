#if DEBUG
import Foundation
import OpenCastCore
import OpenCastTranscription
import Speech

nonisolated struct TranscriptionProofRunner: Sendable {
    static let requestArgument = "--opencast-run-transcription-proof"
    static let appleSpeechRequestArgument = "--opencast-run-apple-speech-transcription-proof"
    static let requestEnvironmentKey = "OPENCAST_RUN_TRANSCRIPTION_PROOF"
    static let engineEnvironmentKey = "OPENCAST_TRANSCRIPTION_PROOF_ENGINE"
    static let feedURLEnvironmentKey = "OPENCAST_TRANSCRIPTION_PROOF_FEED_URL"
    static let feedURLArgument = "--opencast-transcription-proof-feed-url"
    static let episodeTitleEnvironmentKey = "OPENCAST_TRANSCRIPTION_PROOF_EPISODE_TITLE"
    static let episodeTitleArgument = "--opencast-transcription-proof-episode-title"
    static let modelEnvironmentKey = "OPENCAST_TRANSCRIPTION_PROOF_MODEL"
    static let modelArgument = "--opencast-transcription-proof-model"
    static let computeEnvironmentKey = "OPENCAST_TRANSCRIPTION_PROOF_COMPUTE"
    static let computeArgument = "--opencast-transcription-proof-compute"
    static let installModelEnvironmentKey = "OPENCAST_TRANSCRIPTION_PROOF_INSTALL_MODEL"
    static let installModelArgument = "--opencast-transcription-proof-install-model"
    static let appleSpeechLanguageEnvironmentKey = "OPENCAST_APPLE_SPEECH_LANGUAGE"
    static let appleSpeechLanguageArgument = "--opencast-apple-speech-language"
    static let appleSpeechRequiresInstalledAssetsEnvironmentKey = "OPENCAST_APPLE_SPEECH_REQUIRE_INSTALLED_ASSETS"
    static let appleSpeechRequiresInstalledAssetsArgument = "--opencast-apple-speech-require-installed-assets"
    static let appleSpeechAllowsAssetInstallationEnvironmentKey = "OPENCAST_APPLE_SPEECH_ALLOW_ASSET_INSTALLATION"
    static let appleSpeechAllowsAssetInstallationArgument = "--opencast-apple-speech-allow-asset-installation"

    private static let defaultFeedURL = URL(string: "https://feeds.feedburner.com/LibrivoxCommunityPodcast")!
    private static let largeV3ReportFileName = "debuggers-almanac-large-v3-proof.json"
    private static let appleSpeechReportFileName = "debuggers-almanac-apple-speech-proof.json"
    private static let transcriptPreviewLimit = 700

    var feedURL: URL
    var preferredEpisodeTitle: String?
    var engine: TranscriptionProofEngine
    var model: OpenCastWhisperModel
    var computeProfile: OpenCastTranscriptionComputeProfile
    var installsWhisperModelIfNeeded: Bool
    var appleSpeechLanguageCode: String
    var appleSpeechRequiresInstalledAssets: Bool
    var appleSpeechAllowsAssetInstallation: Bool

    @concurrent
    static func runIfRequested() async {
        let processInfo = ProcessInfo.processInfo
        let arguments = Set(processInfo.arguments)
        let environment = processInfo.environment
        let isRequested = arguments.contains(Self.requestArgument)
            || arguments.contains(Self.appleSpeechRequestArgument)
            || environment[Self.requestEnvironmentKey] == "1"
        guard isRequested else {
            return
        }

        let feedURLValue = Self.argumentValue(from: processInfo.arguments, flag: Self.feedURLArgument)
            ?? environment[Self.feedURLEnvironmentKey]
        let feedURL = feedURLValue
            .flatMap(URL.init(string:))
            ?? Self.defaultFeedURL
        let modelValue = Self.argumentValue(from: processInfo.arguments, flag: Self.modelArgument)
            ?? environment[Self.modelEnvironmentKey]
        let computeValue = Self.argumentValue(from: processInfo.arguments, flag: Self.computeArgument)
            ?? environment[Self.computeEnvironmentKey]
        let appleSpeechLanguageCode = Self.argumentValue(
            from: processInfo.arguments,
            flag: Self.appleSpeechLanguageArgument
        )
        ?? environment[Self.appleSpeechLanguageEnvironmentKey]
        ?? "en"
        let runner = TranscriptionProofRunner(
            feedURL: feedURL,
            preferredEpisodeTitle: Self.argumentValue(from: processInfo.arguments, flag: Self.episodeTitleArgument)
                ?? environment[Self.episodeTitleEnvironmentKey],
            engine: TranscriptionProofEngine.selected(arguments: arguments, environment: environment),
            model: Self.model(from: modelValue) ?? .largeV3,
            computeProfile: Self.computeProfile(from: computeValue) ?? .backgroundSafe,
            installsWhisperModelIfNeeded: Self.boolValue(
                from: Self.argumentValue(from: processInfo.arguments, flag: Self.installModelArgument)
                    ?? environment[Self.installModelEnvironmentKey],
                defaultValue: false
            ),
            appleSpeechLanguageCode: appleSpeechLanguageCode,
            appleSpeechRequiresInstalledAssets: Self.boolValue(
                from: Self.argumentValue(
                    from: processInfo.arguments,
                    flag: Self.appleSpeechRequiresInstalledAssetsArgument
                )
                ?? environment[Self.appleSpeechRequiresInstalledAssetsEnvironmentKey],
                defaultValue: true
            ),
            appleSpeechAllowsAssetInstallation: Self.boolValue(
                from: Self.argumentValue(
                    from: processInfo.arguments,
                    flag: Self.appleSpeechAllowsAssetInstallationArgument
                )
                ?? environment[Self.appleSpeechAllowsAssetInstallationEnvironmentKey],
                defaultValue: false
            )
        )
        await runner.run()
    }

    @concurrent
    func run() async {
        let reportURL = Self.reportURL(engine: engine, model: model)
        var report = TranscriptionProofReport(feedURL: feedURL, engine: engine)
        Self.applyInitialEngineFields(
            to: &report,
            engine: engine,
            model: model,
            appleSpeechLanguageCode: appleSpeechLanguageCode,
            appleSpeechRequiresInstalledAssets: appleSpeechRequiresInstalledAssets,
            appleSpeechAllowsAssetInstallation: appleSpeechAllowsAssetInstallation
        )
        if engine == .whisper {
            report.computeProfile = computeProfile.logDescription
        }
        do {
            try Self.prepareProofDirectory()
            try Self.write(report, to: reportURL)

            report.phase = "fetching-feed"
            report.updatedAt = .now
            try Self.write(report, to: reportURL)

            let feed = try await DefaultFeedService().fetchFeed(at: feedURL)
            let episode = try Self.selectedEpisode(
                from: feed,
                preferredEpisodeTitle: preferredEpisodeTitle
            )
            guard let audioURL = episode.audioURL else {
                throw OpenCastCoreError.missingAudioURL
            }

            report.podcastTitle = feed.podcast.title
            report.episodeTitle = episode.title
            report.episodeID = episode.id.rawValue
            report.publishedAt = episode.publishedAt
            report.declaredDuration = episode.duration
            report.sourceAudioURL = audioURL.absoluteString
            report.phase = engine == .appleSpeech ? "checking-apple-speech-assets" : "checking-model"
            report.updatedAt = .now
            try Self.write(report, to: reportURL)

            let modelIdentity: TranscriptionProofModelIdentity
            switch engine {
            case .whisper:
                let modelSummary = try await Self.whisperModelSummary(
                    model: model,
                    installsIfNeeded: installsWhisperModelIfNeeded,
                    report: &report,
                    reportURL: reportURL
                )
                modelIdentity = TranscriptionProofModelIdentity(summary: modelSummary)
            case .appleSpeech:
                let assetStatus = await AppleSpeechTranscriptionService.assetStatus(languageCode: appleSpeechLanguageCode)
                Self.applyAppleSpeechStatus(assetStatus, to: &report)
                let resolvedLocaleIdentifier = assetStatus.resolvedLocaleIdentifier
                    ?? assetStatus.requestedLocaleIdentifier
                modelIdentity = TranscriptionProofModelIdentity(
                    identifier: AppleSpeechTranscriptionService.modelIdentifier(localeIdentifier: resolvedLocaleIdentifier),
                    version: ProcessInfo.processInfo.operatingSystemVersionString,
                    treeSHA256: "asset-status-\(assetStatus.assetInventoryStatus ?? "unknown")-\(resolvedLocaleIdentifier)",
                    byteCount: nil
                )
            }
            report.modelIdentifier = modelIdentity.identifier
            report.modelVersion = modelIdentity.version
            report.modelTreeSHA256 = modelIdentity.treeSHA256
            report.modelByteCount = modelIdentity.byteCount
            report.phase = "downloading-audio"
            report.updatedAt = .now
            try Self.write(report, to: reportURL)

            let audioFileURL = try await Self.downloadAudioIfNeeded(audioURL, episodeID: episode.id.rawValue)
            let audioByteCount = try Self.fileByteCount(at: audioFileURL)
            let audioSHA256 = try await OpenCastSHA256.hashFileOffCaller(at: audioFileURL)
            report.sourceFilePath = audioFileURL.path
            report.sourceFileByteCount = audioByteCount
            report.sourceFileSHA256 = audioSHA256
            report.phase = "transcribing"
            report.updatedAt = .now
            try Self.write(report, to: reportURL)

            let request = OpenCastLongFormTranscriptionRequest(
                audioFileURL: audioFileURL,
                languageCode: engine == .appleSpeech ? appleSpeechLanguageCode : "en",
                sourceAudioURL: audioURL.absoluteString,
                sourceFileByteCount: audioByteCount,
                sourceFileSHA256: audioSHA256,
                modelIdentifier: modelIdentity.identifier,
                modelVersion: modelIdentity.version,
                modelTreeSHA256: modelIdentity.treeSHA256
            )
            let (stream, unloadService) = await Self.transcriptionStream(
                engine: engine,
                model: model,
                computeProfile: computeProfile,
                request: request,
                appleSpeechRequiresInstalledAssets: appleSpeechRequiresInstalledAssets,
                appleSpeechAllowsAssetInstallation: appleSpeechAllowsAssetInstallation
            )
            var finishedResult: OpenCastTranscriptionResult?

            for try await event in stream {
                switch event {
                case .progress(let progress):
                    report.audioDuration = progress.audioDuration
                    report.completedDuration = progress.completedDuration
                    report.checkpointCount = progress.checkpointCount
                    if let currentText = progress.currentText, !currentText.isEmpty {
                        report.textPreview = Self.preview(currentText)
                    }
                case .checkpoint(let checkpoint):
                    report.audioDuration = checkpoint.audioDuration
                    report.completedDuration = checkpoint.completedDuration
                    report.checkpointCount = checkpoint.index
                    report.checkpoints.append(TranscriptionProofCheckpointReport(
                        id: checkpoint.index,
                        completedDuration: checkpoint.completedDuration,
                        segmentCount: checkpoint.segments.count,
                        textPreview: Self.preview(checkpoint.text),
                        createdAt: .now
                    ))
                case .finished(let result):
                    finishedResult = result
                }
                report.updatedAt = .now
                try Self.write(report, to: reportURL)
            }

            guard let result = finishedResult else {
                throw OpenCastTranscriptionError.noTranscriptionResult
            }
            await unloadService()
            let transcriptLocation = try await Self.writeTranscriptDocument(
                result: result,
                episode: episode,
                audioURL: audioURL,
                audioByteCount: audioByteCount,
                audioSHA256: audioSHA256,
                modelIdentity: modelIdentity,
                checkpoints: report.checkpoints
            )

            report.status = "completed"
            report.phase = "completed"
            report.completedAt = .now
            report.updatedAt = report.completedAt ?? .now
            report.audioDuration = result.timings.audioDuration
            report.completedDuration = result.timings.audioDuration
            report.segmentCount = result.segments.count
            report.wordedSegmentCount = result.segments.count(where: { $0.words != nil })
            report.wordCount = result.segments.reduce(0) { $0 + ($1.words?.count ?? 0) }
            report.textCharacterCount = result.text.count
            report.textPreview = Self.preview(result.text)
            report.transcriptRelativePath = transcriptLocation.relativePath
            report.transcriptFilePath = transcriptLocation.fileURL.path
            report.modelLoading = result.timings.modelLoading
            report.audioLoading = result.timings.audioLoading
            report.transcription = result.timings.transcription
            report.fullPipeline = result.timings.fullPipeline
            report.realTimeFactor = result.timings.realTimeFactor
            report.decodingWindowCount = result.timings.decodingWindowCount
            report.decodingFallbackCount = result.timings.decodingFallbackCount
            try Self.write(report, to: reportURL)
        } catch {
            report.status = "failed"
            report.errorMessage = error.localizedDescription
            report.updatedAt = .now
            try? Self.prepareProofDirectory()
            try? Self.write(report, to: reportURL)
        }
    }

    private static func selectedEpisode(
        from feed: FeedSnapshot,
        preferredEpisodeTitle: String?
    ) throws -> Episode {
        if let preferredEpisodeTitle,
           let episode = feed.episodes.first(where: { $0.title.localizedStandardContains(preferredEpisodeTitle) }) {
            return episode
        }

        guard let episode = feed.episodes.first(where: { $0.audioURL != nil }) else {
            throw OpenCastCoreError.missingAudioURL
        }
        return episode
    }

    private static func whisperModelSummary(
        model: OpenCastWhisperModel,
        installsIfNeeded: Bool,
        report: inout TranscriptionProofReport,
        reportURL: URL
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        let installStore = OpenCastWhisperModelInstallStore()
        do {
            return try installStore.installedSummary(
                modelIdentifier: model.rawValue,
                version: model.defaultRemoteVersion
            )
        } catch let error as OpenCastTranscriptionError {
            guard case .modelNotInstalled = error, installsIfNeeded else {
                throw error
            }
        }

        report.modelIdentifier = model.rawValue
        report.modelVersion = model.defaultRemoteVersion
        report.phase = "installing-model"
        report.updatedAt = .now
        try Self.write(report, to: reportURL)

        _ = try await OpenCastWhisperModelInstaller().install(model: model)
        return try installStore.installedSummary(
            modelIdentifier: model.rawValue,
            version: model.defaultRemoteVersion
        )
    }

    private static func downloadAudioIfNeeded(_ audioURL: URL, episodeID: String) async throws -> URL {
        let destination = proofDirectory()
            .appending(path: "Audio", directoryHint: .isDirectory)
            .appending(path: "\(safeStem(episodeID)).mp3")
        if FileManager.default.fileExists(atPath: destination.path),
           (try? fileByteCount(at: destination)) ?? 0 > 0 {
            return destination
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let (temporaryURL, response) = try await URLSession.shared.download(from: audioURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func transcriptionStream(
        engine: TranscriptionProofEngine,
        model: OpenCastWhisperModel,
        computeProfile: OpenCastTranscriptionComputeProfile,
        request: OpenCastLongFormTranscriptionRequest,
        appleSpeechRequiresInstalledAssets: Bool,
        appleSpeechAllowsAssetInstallation: Bool
    ) async -> (
        stream: AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error>,
        unloadService: @Sendable () async -> Void
    ) {
        switch engine {
        case .whisper:
            let service = OpenCastTranscriptionService(
                modelLocator: DownloadedWhisperModelLocator(model: model),
                computeProfile: computeProfile
            )
            return (
                stream: await service.transcribe(request),
                unloadService: {
                    await service.unload()
                }
            )
        case .appleSpeech:
            let service = AppleSpeechTranscriptionService(
                requiresInstalledAssets: appleSpeechRequiresInstalledAssets,
                allowsAssetInstallation: appleSpeechAllowsAssetInstallation
            )
            return (
                stream: service.transcribe(request),
                unloadService: {
                    await service.unload()
                }
            )
        }
    }

    private static func writeTranscriptDocument(
        result: OpenCastTranscriptionResult,
        episode: Episode,
        audioURL: URL,
        audioByteCount: Int64,
        audioSHA256: String,
        modelIdentity: TranscriptionProofModelIdentity,
        checkpoints: [TranscriptionProofCheckpointReport]
    ) async throws -> (relativePath: String, fileURL: URL) {
        let fileStore = await EpisodeTranscriptFileStore()
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: audioSHA256,
            modelIdentifier: modelIdentity.identifier,
            modelVersion: modelIdentity.version,
            modelTreeSHA256: modelIdentity.treeSHA256
        )
        let relativePath = fileStore.relativePath(
            episodeID: episode.id.rawValue,
            fingerprint: fingerprint
        )
        let createdAt = Date.now
        let document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            sourceAudioURL: audioURL.absoluteString,
            sourceFileByteCount: audioByteCount,
            sourceFileSHA256: audioSHA256,
            modelIdentifier: modelIdentity.identifier,
            modelVersion: modelIdentity.version,
            modelTreeSHA256: modelIdentity.treeSHA256,
            languageCode: result.languageCode,
            audioDuration: result.timings.audioDuration,
            checkpoints: checkpoints.map {
                EpisodeTranscriptCheckpoint(
                    id: $0.id,
                    completedDuration: $0.completedDuration,
                    segmentCount: $0.segmentCount,
                    createdAt: $0.createdAt
                )
            },
            segments: result.segments,
            text: result.text,
            timings: EpisodeTranscriptTimings(resultTimings: result.timings),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try fileStore.write(document, relativePath: relativePath)
        return (relativePath, fileStore.fileURL(relativePath: relativePath))
    }

    private static func applyInitialEngineFields(
        to report: inout TranscriptionProofReport,
        engine: TranscriptionProofEngine,
        model: OpenCastWhisperModel,
        appleSpeechLanguageCode: String,
        appleSpeechRequiresInstalledAssets: Bool,
        appleSpeechAllowsAssetInstallation: Bool
    ) {
        switch engine {
        case .whisper:
            report.modelIdentifier = model.rawValue
            report.modelVersion = model.defaultRemoteVersion
        case .appleSpeech:
            let requestedLocaleIdentifier = Locale(identifier: appleSpeechLanguageCode).identifier
            report.modelIdentifier = AppleSpeechTranscriptionService.modelIdentifier(
                localeIdentifier: requestedLocaleIdentifier
            )
            report.modelVersion = ProcessInfo.processInfo.operatingSystemVersionString
            report.appleSpeechRequestedLocaleIdentifier = requestedLocaleIdentifier
            report.appleSpeechRequiresInstalledAssets = appleSpeechRequiresInstalledAssets
            report.appleSpeechAllowsAssetInstallation = appleSpeechAllowsAssetInstallation
            report.speechRecognizerAuthorizationStatus = speechRecognizerAuthorizationStatusDescription()
        }
    }

    private static func applyAppleSpeechStatus(
        _ status: AppleSpeechAssetStatus,
        to report: inout TranscriptionProofReport
    ) {
        report.appleSpeechRequestedLocaleIdentifier = status.requestedLocaleIdentifier
        report.appleSpeechResolvedLocaleIdentifier = status.resolvedLocaleIdentifier
        report.appleSpeechAssetStatus = status.assetInventoryStatus
        report.appleSpeechInstalledLocaleIdentifiers = status.installedLocaleIdentifiers
    }

    private static func prepareProofDirectory() throws {
        try FileManager.default.createDirectory(
            at: proofDirectory(),
            withIntermediateDirectories: true
        )
        try LocalBackupExclusion.apply(to: proofDirectory())
    }

    private static func write(_ report: TranscriptionProofReport, to url: URL) throws {
        var report = report
        report.updatedAt = .now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: [.atomic])
    }

    private static func reportURL(engine: TranscriptionProofEngine, model: OpenCastWhisperModel) -> URL {
        proofDirectory().appending(path: reportFileName(engine: engine, model: model))
    }

    private static func reportFileName(engine: TranscriptionProofEngine, model: OpenCastWhisperModel) -> String {
        switch engine {
        case .appleSpeech:
            appleSpeechReportFileName
        case .whisper:
            switch model {
            case .tinyEnglish:
                "debuggers-almanac-tiny-proof.json"
            case .largeV3:
                largeV3ReportFileName
            }
        }
    }

    private static func model(from value: String?) -> OpenCastWhisperModel? {
        guard let value else {
            return nil
        }

        return OpenCastWhisperModel(commandLineValue: value)
    }

    private static func computeProfile(from value: String?) -> OpenCastTranscriptionComputeProfile? {
        guard let value else {
            return nil
        }

        let normalizedValue = value == "cpuAndNE" ? OpenCastTranscriptionComputeProfile.cpuAndNeuralEngine.rawValue : value
        return OpenCastTranscriptionComputeProfile(rawValue: normalizedValue)
    }

    private static func proofDirectory() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "OpenCastTranscriptionProof", directoryHint: .isDirectory)
    }

    private static func preview(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(transcriptPreviewLimit))
    }

    private static func boolValue(from value: String?, defaultValue: Bool) -> Bool {
        guard let value else {
            return defaultValue
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            return defaultValue
        }
    }

    private static func argumentValue(from arguments: [String], flag: String) -> String? {
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

    private static func speechRecognizerAuthorizationStatusDescription() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            "notDetermined"
        case .denied:
            "denied"
        case .restricted:
            "restricted"
        case .authorized:
            "authorized"
        @unknown default:
            "unknown"
        }
    }

    private static func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0
        else {
            return 0
        }
        return Int64(fileSize)
    }

    private static func safeStem(_ rawValue: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var value = ""
        for scalar in rawValue.unicodeScalars {
            if allowedScalars.contains(scalar) {
                value.unicodeScalars.append(scalar)
            } else {
                value.append("-")
            }
        }

        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return String((trimmed.isEmpty ? "proof-audio" : trimmed).prefix(96))
    }
}

#endif
