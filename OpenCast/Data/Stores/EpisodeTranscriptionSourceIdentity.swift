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
        do {
            return try OpenCastFileByteCount.byteCount(at: url)
        } catch is OpenCastFileByteCount.NotARegularFile {
            throw EpisodeTranscriptionError.missingDownloadedFile
        }
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
