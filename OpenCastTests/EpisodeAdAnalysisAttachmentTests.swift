import Testing
@testable import OpenCast

@Suite("Ad analysis attachment")
struct EpisodeAdAnalysisAttachmentTests {
    @Test(
        "Only a trusted download with the transcript's own bytes attaches the analysis",
        arguments: [
            // Empty hashes prove nothing, on either side.
            ("", "", EpisodeAdAnalysisAttachment.detached),
            ("", "transcript-bytes", .detached),
            ("transcript-bytes", "", .detached),
            // No trusted download: missing, drifted, unhashed or not completed.
            ("transcript-bytes", nil, .detached),
            // A download of other bytes, such as a fresh dynamic-ad assembly.
            ("transcript-bytes", "other-bytes", .detached),
            ("transcript-bytes", "transcript-bytes", .attached)
        ] as [(String, String?, EpisodeAdAnalysisAttachment)]
    )
    func resolvesAttachment(
        transcriptSourceSHA256: String,
        trustedDownloadSHA256: String?,
        expected: EpisodeAdAnalysisAttachment
    ) {
        #expect(EpisodeAdAnalysisAttachment.resolve(
            transcriptSourceSHA256: transcriptSourceSHA256,
            trustedDownloadSHA256: trustedDownloadSHA256
        ) == expected)
    }
}
