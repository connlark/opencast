import OpenCastTranscription

enum TranscriptionModelState: Equatable, Sendable {
    case unknown
    case notInstalled
    case checking
    case installing(OpenCastWhisperModelInstallProgress)
    case installed(OpenCastWhisperModelInstalledSummary)
    case repairAvailable(OpenCastWhisperModelInstalledSummary)
    case deleting
    case failed(String)
}
