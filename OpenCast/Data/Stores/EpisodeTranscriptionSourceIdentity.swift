import AVFoundation
import Foundation
import OpenCastTranscription

struct EpisodeTranscriptionSourceIdentity: Sendable, Equatable {
    var byteCount: Int64
    var sha256: String
    var duration: TimeInterval?

    @concurrent
    static func load(from url: URL) async throws -> EpisodeTranscriptionSourceIdentity {
        async let byteCount = fileByteCount(at: url)
        async let sha256 = OpenCastSHA256.hashFileOffCaller(at: url)
        async let duration = audioDuration(at: url)
        return try await EpisodeTranscriptionSourceIdentity(
            byteCount: byteCount,
            sha256: sha256,
            duration: duration
        )
    }

    private static func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw EpisodeTranscriptionError.missingDownloadedFile
        }
        return Int64(fileSize)
    }

    private static func audioDuration(at url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                return nil
            }
            return duration
        } catch {
            return nil
        }
    }
}
