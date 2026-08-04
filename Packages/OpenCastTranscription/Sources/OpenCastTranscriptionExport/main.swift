import Foundation
import OpenCastTranscription

@main
struct OpenCastTranscriptionExport {
    static func main() async throws {
        let options = try ExportOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let audioURL = URL(fileURLWithPath: options.audioPath)
        let outputURL = URL(fileURLWithPath: options.outputPath)
        let sourceFileByteCount = try fileByteCount(at: audioURL)
        let sourceFileSHA256 = try OpenCastSHA256.hashFile(at: audioURL)
        let modelStore = options.modelRootPath.map {
            OpenCastWhisperModelInstallStore(rootDirectory: URL(fileURLWithPath: $0))
        } ?? OpenCastWhisperModelInstallStore()
        let modelSummary = try modelStore.installedSummary(
            modelIdentifier: options.model.rawValue,
            version: options.model.defaultRemoteVersion
        )
        let service = OpenCastTranscriptionService(
            modelLocator: DownloadedWhisperModelLocator(model: options.model, installStore: modelStore)
        )
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            sourceAudioURL: audioURL.absoluteString,
            sourceFileByteCount: sourceFileByteCount,
            sourceFileSHA256: sourceFileSHA256,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256
        )

        var checkpoints: [ExportCheckpoint] = []
        var finishedResult: OpenCastTranscriptionResult?
        let startedAt = Date.now
        for try await event in await service.transcribe(request) {
            switch event {
            case .progress(let progress):
                print("progress completed=\(progress.completedDuration) checkpoints=\(progress.checkpointCount)")
            case .checkpoint(let checkpoint):
                checkpoints.append(ExportCheckpoint(
                    id: checkpoint.index,
                    completedDuration: checkpoint.completedDuration,
                    segmentCount: checkpoint.segments.count,
                    createdAt: Date.now
                ))
                print("checkpoint \(checkpoint.index) completed=\(checkpoint.completedDuration) segments=\(checkpoint.segments.count)")
            case .finished(let result):
                finishedResult = result
            }
        }
        await service.unload()

        guard let result = finishedResult else {
            throw ExportError.missingResult
        }

        let document = ExportTranscriptDocument(
            schemaVersion: 1,
            episodeID: options.episodeID,
            podcastID: options.podcastID,
            episodeTitle: options.episodeTitle,
            podcastTitle: options.podcastTitle,
            sourceAudioURL: audioURL.absoluteString,
            sourceFileByteCount: sourceFileByteCount,
            sourceFileSHA256: sourceFileSHA256,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256,
            languageCode: result.languageCode,
            audioDuration: result.timings.audioDuration,
            checkpoints: checkpoints,
            segments: result.segments,
            text: result.text,
            timings: ExportTimings(result.timings),
            createdAt: startedAt,
            updatedAt: Date.now
        )

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: outputURL, options: [.atomic])
        print("wrote \(outputURL.path)")
    }

    private static func fileByteCount(at url: URL) throws -> Int64 {
        do {
            return try OpenCastFileByteCount.byteCount(at: url)
        } catch is OpenCastFileByteCount.NotARegularFile {
            return 0
        }
    }
}

struct ExportOptions {
    var audioPath: String
    var outputPath: String
    var modelRootPath: String?
    var model: OpenCastWhisperModel
    var episodeID: String
    var podcastID: String
    var episodeTitle: String?
    var podcastTitle: String?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw ExportError.invalidArguments
            }
            values[String(key.dropFirst(2))] = arguments[index + 1]
            index += 2
        }

        guard let audioPath = values["audio"],
              let outputPath = values["output"],
              let episodeID = values["episode-id"],
              let podcastID = values["podcast-id"]
        else {
            throw ExportError.invalidArguments
        }

        self.audioPath = audioPath
        self.outputPath = outputPath
        modelRootPath = values["model-root"]
        model = try Self.model(from: values["model"])
        self.episodeID = episodeID
        self.podcastID = podcastID
        episodeTitle = values["episode-title"]
        podcastTitle = values["podcast-title"]
    }

    private static func model(from value: String?) throws -> OpenCastWhisperModel {
        guard let value else {
            return .largeV3
        }

        guard let model = OpenCastWhisperModel(commandLineValue: value) else {
            throw ExportError.invalidArguments
        }
        return model
    }
}

enum ExportError: Error, LocalizedError {
    case invalidArguments
    case missingResult

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: OpenCastTranscriptionExport --audio PATH --output PATH --episode-id ID --podcast-id ID [--model tiny|large-v3] [--model-root PATH] [--episode-title TITLE] [--podcast-title TITLE]"
        case .missingResult:
            "Transcription finished without a final result."
        }
    }
}

struct ExportTranscriptDocument: Codable {
    var schemaVersion: Int
    var episodeID: String
    var podcastID: String
    var episodeTitle: String?
    var podcastTitle: String?
    var sourceAudioURL: String
    var sourceFileByteCount: Int64
    var sourceFileSHA256: String
    var modelIdentifier: String
    var modelVersion: String
    var modelTreeSHA256: String
    var languageCode: String
    var audioDuration: TimeInterval
    var checkpoints: [ExportCheckpoint]
    var segments: [OpenCastTranscriptSegment]
    var text: String
    var timings: ExportTimings
    var createdAt: Date
    var updatedAt: Date
}

struct ExportCheckpoint: Codable {
    var id: Int
    var completedDuration: TimeInterval
    var segmentCount: Int
    var createdAt: Date
}

struct ExportTimings: Codable {
    var modelLoading: TimeInterval
    var audioLoading: TimeInterval
    var transcription: TimeInterval
    var fullPipeline: TimeInterval
    var realTimeFactor: Double
    var decodingFallbackCount: Int
    var decodingFallback: TimeInterval
    var decodingWindowCount: Int

    init(_ timings: OpenCastTranscriptionTimings) {
        modelLoading = timings.modelLoading
        audioLoading = timings.audioLoading
        transcription = timings.transcription
        fullPipeline = timings.fullPipeline
        realTimeFactor = timings.realTimeFactor
        decodingFallbackCount = timings.decodingFallbackCount
        decodingFallback = timings.decodingFallback
        decodingWindowCount = timings.decodingWindowCount
    }
}
