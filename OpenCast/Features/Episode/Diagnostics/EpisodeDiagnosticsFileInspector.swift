import AVFoundation
import Foundation
import OpenCastTranscription

nonisolated struct EpisodeDiagnosticsFileInspector: EpisodeDiagnosticsFileInspecting {
    @concurrent
    func fileInfo(at url: URL) async -> EpisodeDiagnosticsFileInfo {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return EpisodeDiagnosticsFileInfo(
                exists: true,
                byteCount: (attributes[.size] as? NSNumber)?.int64Value
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return EpisodeDiagnosticsFileInfo(exists: false, byteCount: nil)
        } catch {
            return EpisodeDiagnosticsFileInfo(
                exists: false,
                byteCount: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    func sha256(at url: URL) async throws -> String {
        try await OpenCastSHA256.hashFileOffCaller(at: url)
    }

    func audioDuration(at url: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: url).load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return seconds
    }
}
