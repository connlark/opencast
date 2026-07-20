import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Transcription model store")
struct TranscriptionModelStoreTests {
    @Test("Missing model loads as not installed")
    func missingModelLoadsAsNotInstalled() {
        let store = TranscriptionModelStore(installer: FakeTranscriptionModelInstaller(isInstalled: false))

        store.loadLocalStatus()

        #expect(store.state == .notInstalled)
    }

    @Test("Fast model requires remote install")
    func fastModelRequiresRemoteInstall() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = TranscriptionModelStore(installer: FakeTranscriptionModelInstaller(isInstalled: false))

        #expect(store.setSelectedChoice(.fastTinyEnglish, modelContext: context))

        #expect(store.selectedChoice == .fastTinyEnglish)
        #expect(!store.canStartTranscription)
        #expect(store.installedSummary == nil)
        #expect(store.state == .notInstalled)
    }

    @Test("Default model choice is fast tiny and stored explicit choice is respected")
    func defaultChoiceIsFastTinyAndStoredChoiceWins() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let defaultStore = TranscriptionModelStore(installer: FakeTranscriptionModelInstaller(isInstalled: false))

        defaultStore.load(modelContext: context)

        #expect(TranscriptionModelChoice.defaultChoice == .fastTinyEnglish)
        #expect(defaultStore.selectedChoice == .fastTinyEnglish)
        #expect(defaultStore.setSelectedChoice(.accurateLargeV3, modelContext: context))

        let reloadedStore = TranscriptionModelStore(installer: FakeTranscriptionModelInstaller(isInstalled: false))
        reloadedStore.load(modelContext: context)

        #expect(reloadedStore.selectedChoice == .accurateLargeV3)
    }

    @Test("Model choice persists through local load")
    func modelChoicePersistsThroughLocalLoad() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let firstStore = TranscriptionModelStore(installer: FakeTranscriptionModelInstaller(isInstalled: false))

        #expect(firstStore.setSelectedChoice(.fastTinyEnglish, modelContext: context))

        let secondStore = TranscriptionModelStore(installer: FakeTranscriptionModelInstaller(isInstalled: false))
        secondStore.load(modelContext: context)

        #expect(secondStore.selectedChoice == .fastTinyEnglish)
        #expect(!secondStore.canStartTranscription)
    }

    @Test("Active transcription blocks model choice changes with message")
    func activeTranscriptionBlocksModelChoiceChangesWithMessage() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "active model choice audio")
        let installer = FakeTranscriptionModelInstaller(isInstalled: true)
        let transcriptionModels = TranscriptionModelStore(installer: installer)
        let blockingTranscriber = BlockingModelChoiceEpisodeTranscriber()
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: blockingTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let appModel = OpenCastAppModel(
            transcriptionModels: transcriptionModels,
            transcriptions: transcriptions,
            allowsAutomaticFeedRefresh: false
        )
        transcriptionModels.load(modelContext: context)
        let episode = makeEpisode(episodeID: "active-model-choice")
        let record = completedDownloadRecord(episode: episode)

        transcriptions.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: installer.summary,
            modelContext: context
        )

        #expect(await waitUntil { blockingTranscriber.requestCount == 1 })
        #expect(!appModel.setTranscriptionModelChoice(.fastTinyEnglish, modelContext: context))
        if case .failed(let message) = transcriptionModels.state {
            #expect(message == "Finish or cancel the active transcript before changing the speech model.")
        } else {
            Issue.record("Expected failed model-choice state, got \(transcriptionModels.state).")
        }

        #expect(!appModel.installTranscriptionModel())
        #expect(installer.requestedInstallModel == nil)
        #expect(transcriptionModels.selectedChoice == .fastTinyEnglish)
        if case .failed(let message) = transcriptionModels.state {
            #expect(message == "Finish or cancel the active transcript before installing the speech model.")
        } else {
            Issue.record("Expected failed model-install state, got \(transcriptionModels.state).")
        }

        await transcriptions.unloadRuntime()
    }

    @Test("Install progress updates state and finishes installed")
    func installProgressUpdatesStateAndFinishesInstalled() async {
        let installer = FakeTranscriptionModelInstaller(isInstalled: false)
        let store = TranscriptionModelStore(installer: installer)

        #expect(store.installPinnedModel())

        #expect(await waitUntil {
            if case .installing(let progress) = store.state {
                progress.totalByteCount == 10
            } else {
                false
            }
        })
        #expect(await waitUntil {
            if case .installed(let summary) = store.state {
                summary.treeSHA256 == installer.summary.treeSHA256
            } else {
                false
            }
        })
    }

    @Test("Starting install reports false while another model operation is active")
    func startingInstallReportsFalseWhileAnotherModelOperationIsActive() async {
        let installer = FakeTranscriptionModelInstaller(isInstalled: false)
        let store = TranscriptionModelStore(installer: installer)

        #expect(store.installPinnedModel())
        #expect(!store.installPinnedModel())

        #expect(await waitUntil {
            if case .installed = store.state {
                true
            } else {
                false
            }
        })
        #expect(installer.installRequestCount == 1)
    }

    @Test("Installing fast model uses tiny remote release")
    func installingFastModelUsesTinyRemoteRelease() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let summary = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "c", count: 64)
        )
        let installer = FakeTranscriptionModelInstaller(isInstalled: false, summary: summary)
        let store = TranscriptionModelStore(installer: installer)

        #expect(store.setSelectedChoice(.fastTinyEnglish, modelContext: context))
        #expect(store.installPinnedModel())

        #expect(await waitUntil {
            if case .installed(let installedSummary) = store.state {
                installedSummary.modelIdentifier == OpenCastWhisperModel.tinyEnglish.rawValue
            } else {
                false
            }
        })
        #expect(installer.requestedInstallModel == .tinyEnglish)
        #expect(installer.requestedInstallVersion == OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion)
    }

    @Test("Late install progress cannot overwrite installed state")
    func lateInstallProgressCannotOverwriteInstalledState() async {
        let installer = FakeTranscriptionModelInstaller(isInstalled: false)
        let store = TranscriptionModelStore(installer: installer)

        #expect(store.installPinnedModel())

        #expect(await waitUntil {
            if case .installed = store.state {
                true
            } else {
                false
            }
        })
        #expect(installer.emitLateProgress())
        #expect(await waitUntil { installer.lateProgressDeliveryAcknowledged })
        if case .installed(let summary) = store.state {
            #expect(summary.treeSHA256 == installer.summary.treeSHA256)
        } else {
            Issue.record("Expected installed state after late progress, got \(store.state)")
        }
    }

    @Test("Manifest mismatch reports repair")
    func manifestMismatchReportsRepair() async {
        let installed = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "1", count: 64)
        )
        let remote = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: installed.modelIdentifier,
            version: installed.version,
            totalByteCount: installed.totalByteCount,
            treeSHA256: String(repeating: "2", count: 64)
        )
        let store = TranscriptionModelStore(installer: FakeTranscriptionModelInstaller(
            isInstalled: true,
            summary: installed,
            manifestSummary: remote
        ))

        store.checkRemoteManifest()

        #expect(await waitUntil {
            if case .repairAvailable(let summary) = store.state {
                summary.treeSHA256 == installed.treeSHA256
            } else {
                false
            }
        })
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Example Show",
            title: "Example Episode",
            summary: nil,
            publishedAt: nil,
            duration: 60,
            audioURL: "https://example.com/\(episodeID).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: episodeID,
            cachedAt: .now
        )
    }

    private func completedDownloadRecord(episode: EpisodeListItemSnapshot) -> EpisodeDownloadRecord {
        EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            localRelativePath: "EpisodeDownloads/\(episode.episodeID).mp3",
            state: .completed,
            bytesReceived: 10,
            bytesExpected: 10
        )
    }

    private func writeAudioPlaceholder(in directory: URL, contents: String) throws -> URL {
        let url = directory.appending(path: UUID().uuidString).appendingPathExtension("mp3")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastTranscriptionModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class FakeTranscriptionModelInstaller: TranscriptionModelInstalling, @unchecked Sendable {
    var isInstalled: Bool
    let summary: OpenCastWhisperModelInstalledSummary
    let manifestSummary: OpenCastWhisperModelInstalledSummary
    var installRequestCount = 0
    var requestedInstallModel: OpenCastWhisperModel?
    var requestedInstallVersion: String?
    private(set) var lateProgressDeliveryAcknowledged = false
    private var installProgress: OpenCastWhisperModelInstallProgressHandler?

    init(
        isInstalled: Bool,
        summary: OpenCastWhisperModelInstalledSummary = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "a", count: 64)
        ),
        manifestSummary: OpenCastWhisperModelInstalledSummary? = nil
    ) {
        self.isInstalled = isInstalled
        self.summary = summary
        self.manifestSummary = manifestSummary ?? summary
    }

    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        guard isInstalled,
              summary.modelIdentifier == model.rawValue,
              summary.version == version else {
            throw OpenCastTranscriptionError.modelNotInstalled(
                modelIdentifier: model.rawValue,
                version: version
            )
        }
        return summary
    }

    func fetchManifest() async throws -> RemoteWhisperModelManifest {
        RemoteWhisperModelManifest(
            schemaVersion: 1,
            generatedAt: "2026-06-29T00:00:00Z",
            models: [remoteModel(summary: manifestSummary)]
        )
    }

    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        installRequestCount += 1
        requestedInstallModel = model
        requestedInstallVersion = version
        installProgress = progress
        progress?(OpenCastWhisperModelInstallProgress(
            modelIdentifier: summary.modelIdentifier,
            version: summary.version,
            completedFileCount: 1,
            totalFileCount: 2,
            completedByteCount: 5,
            totalByteCount: 10,
            currentFilePath: "model/config.json"
        ))
        try await Task.sleep(for: .milliseconds(40))
        isInstalled = true
        return summary
    }

    func emitLateProgress() -> Bool {
        guard let installProgress else {
            return false
        }

        installProgress(OpenCastWhisperModelInstallProgress(
            modelIdentifier: summary.modelIdentifier,
            version: summary.version,
            completedFileCount: 1,
            totalFileCount: 2,
            completedByteCount: 6,
            totalByteCount: 10,
            currentFilePath: "model/late.bin"
        ))
        Task { @MainActor [weak self] in
            self?.lateProgressDeliveryAcknowledged = true
        }
        return true
    }

    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws {
        isInstalled = false
    }

    private func remoteModel(summary: OpenCastWhisperModelInstalledSummary) -> RemoteWhisperModel {
        RemoteWhisperModel(
            modelID: summary.modelIdentifier,
            version: summary.version,
            modelFolder: "model",
            tokenizerFolder: "tokenizer",
            totalByteCount: summary.totalByteCount,
            treeSHA256: summary.treeSHA256,
            files: []
        )
    }
}

private final class BlockingModelChoiceEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requestCount = 0

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.progress(EpisodeTranscriptionProgress(
                    audioDuration: 60,
                    completedDuration: 0,
                    checkpointCount: 0,
                    currentWindowIndex: 0,
                    currentText: nil
                )))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func unload() async {
    }
}
