import Foundation

enum AdFreePassBackgroundRunLog {
    #if DEBUG
    /// One rotation generation keeps total disk use bounded at ~2× this cap.
    static let defaultMaximumByteCount = 512 * 1024

    static func record(_ message: String) {
        record(message, logURL: logURL)
    }

    /// Test seam: explicit log URL and cap.
    static func record(
        _ message: String,
        logURL: URL,
        maximumByteCount: Int = defaultMaximumByteCount
    ) {
        let line = "\(Date.now) \(sanitize(message))\n"
        let data = Data(line.utf8)
        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded(logURL: logURL, incomingByteCount: data.count, maximumByteCount: maximumByteCount)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            handle.write(data)
            try handle.close()
        } catch {
            assertionFailure("Ad-free pass background log failed: \(error.localizedDescription)")
        }
    }

    private static func rotateIfNeeded(logURL: URL, incomingByteCount: Int, maximumByteCount: Int) {
        // FileManager attributes, not URL.resourceValues: NSURL caches
        // resource values per instance, so a reused URL would report a
        // stale size and the rotation would never trigger.
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let currentByteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard currentByteCount + incomingByteCount > maximumByteCount else {
            return
        }

        let previousURL = logURL.appendingPathExtension("previous")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: logURL, to: previousURL)
    }

    private static var logURL: URL {
        URL.documentsDirectory.appending(path: "adfreepass-bg-session.log")
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
    #else
    static func record(_ message: String) {}
    #endif
}

extension EpisodeAdFreePassStage {
    var backgroundRunLogDescription: String {
        switch self {
        case .idle:
            "idle"
        case .awaitingModelDownloadConsent(let byteCount):
            "awaitingModelDownloadConsent byteCount=\(byteCount)"
        case .downloadingEpisode:
            "downloadingEpisode"
        case .installingModel(let progress):
            "installingModel model=\(progress.modelIdentifier) version=\(progress.version) bytes=\(progress.completedByteCount)/\(progress.totalByteCount) files=\(progress.completedFileCount)/\(progress.totalFileCount)"
        case .installingSpeechAssets(let fractionCompleted):
            "installingSpeechAssets fraction=\(fractionCompleted.backgroundLogNumber)"
        case .transcribing(let progress):
            "transcribing completed=\(progress.completedDuration.backgroundLogSeconds) audio=\(progress.audioDuration.backgroundLogSeconds) checkpoints=\(progress.checkpointCount) window=\(progress.currentWindowIndex.map(String.init) ?? "nil")"
        case .analyzing:
            "analyzing"
        case .cloudQueued:
            "cloudQueued"
        case .cloudTranscribing(let progress):
            "cloudTranscribing fraction=\((progress?.fractionCompleted ?? 0).backgroundLogNumber)"
        case .cloudDetectingAds:
            "cloudDetectingAds"
        case .cloudUnavailable(let message):
            "cloudUnavailable message=\(message)"
        case .completed(let zoneCount):
            "completed zoneCount=\(zoneCount)"
        case .interrupted:
            "interrupted"
        case .failed(let message):
            "failed message=\(message)"
        case .unavailable(let message):
            "unavailable message=\(message)"
        }
    }

    var backgroundLogStageKind: String {
        // Environment snapshots need a stable case key, not the verbose log line with progress details.
        switch self {
        case .idle:
            "idle"
        case .awaitingModelDownloadConsent:
            "awaitingModelDownloadConsent"
        case .downloadingEpisode:
            "downloadingEpisode"
        case .installingModel:
            "installingModel"
        case .installingSpeechAssets:
            "installingSpeechAssets"
        case .transcribing:
            "transcribing"
        case .analyzing:
            "analyzing"
        case .cloudQueued:
            "cloudQueued"
        case .cloudTranscribing:
            "cloudTranscribing"
        case .cloudDetectingAds:
            "cloudDetectingAds"
        case .cloudUnavailable:
            "cloudUnavailable"
        case .completed:
            "completed"
        case .interrupted:
            "interrupted"
        case .failed:
            "failed"
        case .unavailable:
            "unavailable"
        }
    }
}

extension BinaryFloatingPoint {
    var backgroundLogNumber: String {
        Double(self).formatted(.number.precision(.fractionLength(3)))
    }
}

extension TimeInterval {
    var backgroundLogSeconds: String {
        backgroundLogNumber
    }
}
