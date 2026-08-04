import Foundation
import OpenCastPlayback

extension OpenCastAppModel {
    /// Appended to the Now Playing diagnostics text so one report establishes
    /// both source-identity invariants for the current episode: which bytes
    /// the transcript and download recorded, which asset the live player item
    /// actually loaded, whether their timelines agree, and the resulting
    /// alignment verdict — plus the build that produced the report.
    var playbackSourceIdentityDiagnostics: String {
        guard let episodeID = playback.currentEpisode?.id.rawValue else {
            return ""
        }

        let transcriptRecord = transcriptions.record(for: episodeID)
        let downloadRecord = downloads.record(for: episodeID)
        let itemIdentity = playback.currentItemSourceIdentity
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: transcriptRecord?.sourceFileSHA256 ?? "",
            trustedDownloadSHA256: downloads.completedSourceIdentity(for: episodeID)?.sha256,
            downloadFileURL: downloadRecord.flatMap(downloads.localFileURL(for:)),
            playerItemURL: itemIdentity?.assetURL
        )

        return """


        app.build: \(diagnosticsValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)) (\(diagnosticsValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)))
        sourceIdentity.transcript.sha256: \(diagnosticsValue(transcriptRecord?.sourceFileSHA256))
        sourceIdentity.transcript.audioDuration: \(diagnosticsSeconds(transcriptRecord?.audioDuration))
        sourceIdentity.download.sha256: \(diagnosticsValue(downloadRecord?.sourceFileSHA256))
        sourceIdentity.download.trusted.sha256: \(diagnosticsValue(downloads.completedSourceIdentity(for: episodeID)?.sha256))
        sourceIdentity.player.assetURL: \(diagnosticsValue(itemIdentity?.assetURL.absoluteString))
        sourceIdentity.player.kind: \(diagnosticsItemKind(itemIdentity?.kind))
        sourceIdentity.player.itemDuration: \(diagnosticsSeconds(itemIdentity?.itemDuration))
        sourceIdentity.alignment: \(diagnosticsAlignment(alignment))
        """
    }

    private func diagnosticsValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "nil"
        }
        return value
    }

    private func diagnosticsSeconds(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else {
            return "nil"
        }
        return value.formatted(.number.precision(.fractionLength(3)))
    }

    private func diagnosticsItemKind(_ kind: PlaybackItemSourceIdentity.Kind?) -> String {
        switch kind {
        case .localFile:
            "local file"
        case .networkStream:
            "network stream"
        case nil:
            "nil"
        }
    }

    private func diagnosticsAlignment(_ alignment: TranscriptSourceAlignment) -> String {
        switch alignment {
        case .verified:
            "verified"
        case .mismatched(let canSwitch):
            "mismatched (switchable=\(canSwitch))"
        }
    }
}
