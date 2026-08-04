import Foundation
import Testing
@testable import OpenCast

/// Regression coverage for the transcript source-identity invariant: karaoke
/// may trust the player only when the live `AVPlayerItem` provably plays the
/// exact bytes the transcript was generated from. Dynamic enclosure URLs
/// return byte-different assemblies per request, so URL equality proves
/// nothing — and durations are deliberately not compared, because stale Xing
/// headers in DAI-stitched MP3s make container and decoded-PCM durations
/// disagree by seconds on the identical file.
@Suite("Transcript source alignment")
struct TranscriptSourceAlignmentTests {
    private let transcribedSHA = "sha-source-a"
    private let differentAssemblySHA = "sha-source-b"
    private let downloadFileURL = URL(filePath: "/downloads/episode-1.mp3")
    private let streamURL = URL(string: "https://example.com/e/traffic.host.fm/episode-1.mp3")!

    @Test("Matching download playing as the live item is verified")
    func matchingDownloadCurrentItemIsVerified() {
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: transcribedSHA,
            trustedDownloadSHA256: transcribedSHA,
            downloadFileURL: downloadFileURL,
            playerItemURL: downloadFileURL
        )
        #expect(alignment == .verified)
    }

    @Test("A stream item while the matching download exists offers a switch")
    func streamWhileMatchingDownloadExistsOffersSwitch() {
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: transcribedSHA,
            trustedDownloadSHA256: transcribedSHA,
            downloadFileURL: downloadFileURL,
            playerItemURL: streamURL
        )
        #expect(alignment == .mismatched(canSwitchToTranscribedCopy: true))
    }

    @Test("No trusted download leaves the stream unproven with no switch")
    func noTrustedDownloadIsMismatchedWithoutSwitch() {
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: transcribedSHA,
            trustedDownloadSHA256: nil,
            downloadFileURL: nil,
            playerItemURL: streamURL
        )
        #expect(alignment == .mismatched(canSwitchToTranscribedCopy: false))
    }

    @Test("A re-downloaded assembly never verifies the old transcript, even as the live item")
    func redownloadedDifferentAssemblyIsMismatched() {
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: transcribedSHA,
            trustedDownloadSHA256: differentAssemblySHA,
            downloadFileURL: downloadFileURL,
            playerItemURL: downloadFileURL
        )
        #expect(alignment == .mismatched(canSwitchToTranscribedCopy: false))
    }

    @Test("A document without recorded provenance can never verify")
    func emptyDocumentHashNeverVerifies() {
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: "",
            trustedDownloadSHA256: "",
            downloadFileURL: downloadFileURL,
            playerItemURL: downloadFileURL
        )
        #expect(alignment == .mismatched(canSwitchToTranscribedCopy: false))
    }

    @Test("Nothing loaded is mismatched but still offers the matched copy")
    func nilCurrentItemStillOffersMatchedCopy() {
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: transcribedSHA,
            trustedDownloadSHA256: transcribedSHA,
            downloadFileURL: downloadFileURL,
            playerItemURL: nil
        )
        #expect(alignment == .mismatched(canSwitchToTranscribedCopy: true))
    }

    @Test("An item at the download path does not verify without a hash match")
    func matchingPathWithoutHashMatchDoesNotVerify() {
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: transcribedSHA,
            trustedDownloadSHA256: nil,
            downloadFileURL: downloadFileURL,
            playerItemURL: downloadFileURL
        )
        #expect(alignment == .mismatched(canSwitchToTranscribedCopy: false))
    }

    @Test(
        "Download-matches-transcript policy is engine independent and requires both hashes",
        arguments: [
            ("sha-source-a", "sha-source-a", true),
            ("sha-source-a", "sha-source-b", false),
            ("", "sha-source-a", false),
            ("sha-source-a", "", false)
        ]
    )
    func downloadMatchPolicy(documentSHA256: String, trustedSHA256: String, matches: Bool) {
        #expect(
            TranscriptSourceAlignment.downloadMatchesTranscript(
                trustedDownloadSHA256: trustedSHA256,
                documentSHA256: documentSHA256
            ) == matches
        )
    }

    @Test("A nil trusted hash never matches")
    func nilTrustedHashNeverMatches() {
        #expect(
            !TranscriptSourceAlignment.downloadMatchesTranscript(
                trustedDownloadSHA256: nil,
                documentSHA256: transcribedSHA
            )
        )
    }
}
