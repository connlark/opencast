import Foundation
import SwiftData
import UIKit

enum OpenCastUITestSeedData {
    static let feedURL = "https://example.com/ui-test-feed.xml"
    static let podcastTitle = "UI Test Show"
    static let episodeID = "ui-test-episode-1"
    static let episodeTitle = "Deterministic UI Episode"
    static let completedEpisodeID = "ui-test-episode-completed"
    static let completedEpisodeTitle = "Completed UI Episode"

    static func seed(
        in container: ModelContainer,
        includesCompletedDownload: Bool = false,
        includesEpisodeProgress: Bool = false
    ) throws {
        let context = ModelContext(container)
        let publishedAt = Date(timeIntervalSince1970: 1_777_776_000)
        let completedPublishedAt = Date(timeIntervalSince1970: 1_777_775_000)
        let refreshedAt = Date(timeIntervalSince1970: 1_777_776_500)
        let artworkURL = try deterministicArtworkURL()?.absoluteString
        let usesVariedArtworkPreviews = ProcessInfo.processInfo.environment[
            "OPENCAST_SEED_VARIED_ARTWORK_PREVIEWS"
        ] == "1"
        let artworkPreview = seededArtworkPreview(
            artworkURL: artworkURL,
            variantIndex: usesVariedArtworkPreviews ? 0 : nil
        )
        let usesBadAudioURL = ProcessInfo.processInfo.environment["OPENCAST_SEED_BAD_AUDIO_URL"] == "1"
        let usesLongShowNotes = ProcessInfo.processInfo.environment["OPENCAST_SEED_LONG_SHOW_NOTES"] == "1"
        let extraFeedCount = Int(ProcessInfo.processInfo.environment["OPENCAST_SEED_EXTRA_FEED_COUNT"] ?? "") ?? 0
        let audioURL = usesBadAudioURL
            ? "file:///tmp/opencast-ui-test-missing-audio.wav"
            : try writeDeterministicAudio().absoluteString
        let showNotesHTML = usesLongShowNotes
            ? longShowNotesHTML()
            : "<p>Deterministic show notes for UI tests.</p>"

        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: podcastTitle,
                author: "UI Test Author",
                artworkURL: artworkURL,
                lastRefreshAt: refreshedAt
            )
        )
        let podcast = PodcastCacheRecord(
            feedURL: feedURL,
            title: podcastTitle,
            author: "UI Test Author",
            summary: "A deterministic show seeded for UI tests.",
            websiteURL: "https://example.com/ui-test-show",
            artworkURL: artworkURL,
            updatedAt: refreshedAt
        )
        if let artworkPreview {
            podcast.storeArtworkPreviewIfChanged(artworkPreview)
        }
        context.insert(podcast)

        let episode = EpisodeCacheRecord(
            episodeID: episodeID,
            podcastID: feedURL,
            podcastTitle: podcastTitle,
            title: episodeTitle,
            summary: "A deterministic episode seeded for UI tests.",
            showNotesHTML: showNotesHTML,
            publishedAt: publishedAt,
            duration: 180,
            audioURL: audioURL,
            artworkURL: artworkURL,
            guid: episodeID,
            cachedAt: refreshedAt
        )
        if let artworkPreview {
            episode.storeArtworkPreviewIfChanged(artworkPreview)
        }
        context.insert(episode)

        seedExtraFeeds(
            count: extraFeedCount,
            context: context,
            audioURL: audioURL,
            artworkURL: artworkURL,
            artworkPreview: artworkPreview,
            usesVariedArtworkPreviews: usesVariedArtworkPreviews,
            refreshedAt: refreshedAt
        )

        if includesEpisodeProgress {
            let completedEpisode = EpisodeCacheRecord(
                episodeID: completedEpisodeID,
                podcastID: feedURL,
                podcastTitle: podcastTitle,
                title: completedEpisodeTitle,
                summary: "A completed deterministic episode seeded for UI tests.",
                showNotesHTML: "<p>Completed deterministic show notes for UI tests.</p>",
                publishedAt: completedPublishedAt,
                duration: 180,
                audioURL: audioURL,
                artworkURL: artworkURL,
                guid: completedEpisodeID,
                cachedAt: refreshedAt
            )
            if let artworkPreview {
                completedEpisode.storeArtworkPreviewIfChanged(artworkPreview)
            }
            context.insert(completedEpisode)
            context.insert(
                EpisodeProgressRecord(
                    episodeID: episodeID,
                    podcastID: feedURL,
                    position: 90,
                    duration: 180,
                    isPlayed: false,
                    updatedAt: refreshedAt
                )
            )
            context.insert(LocalPreferenceRecord(key: "playback.lastEpisodeID", value: episodeID))
            context.insert(
                EpisodeProgressRecord(
                    episodeID: completedEpisodeID,
                    podcastID: feedURL,
                    position: 140,
                    duration: 180,
                    isPlayed: true,
                    updatedAt: completedPublishedAt
                )
            )
        }

        let seededVoiceBoostMode = ProcessInfo.processInfo.environment[
            OpenCastLaunchConfiguration.seedVoiceBoostModeEnvironmentKey
        ]
        if seededVoiceBoostMode == VoiceBoostMode.perEpisode.rawValue {
            context.insert(LocalPreferenceRecord(
                key: PlaybackSettingsStore.voiceBoostModePreferenceKey,
                value: VoiceBoostMode.perEpisode.rawValue
            ))
        }

        if includesCompletedDownload {
            let fileStore = EpisodeDownloadFileStore()
            let sourceURL = URL(string: audioURL)!
            let relativePath = fileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceURL)
            let fileURL = fileStore.fileURL(relativePath: relativePath)
            let data = Data("OpenCast UI test downloaded audio".utf8)
            try fileStore.prepareDownloadsDirectory()
            try data.write(to: fileURL, options: .atomic)
            context.insert(
                EpisodeDownloadRecord(
                    episodeID: episodeID,
                    podcastID: feedURL,
                    sourceAudioURL: audioURL,
                    localRelativePath: relativePath,
                    state: .completed,
                    bytesReceived: Int64(data.count),
                    bytesExpected: Int64(data.count),
                    createdAt: refreshedAt,
                    updatedAt: refreshedAt
                )
            )
        }

        try context.save()
    }

    private static func seedExtraFeeds(
        count: Int,
        context: ModelContext,
        audioURL: String,
        artworkURL: String?,
        artworkPreview: ArtworkPreview?,
        usesVariedArtworkPreviews: Bool,
        refreshedAt: Date
    ) {
        guard count > 0 else {
            return
        }

        for index in 1...count {
            let feedURL = "https://example.com/ui-test-extra-\(index).xml"
            let title = "UI Test Extra Show \(index)"
            let episodeID = "ui-test-extra-episode-\(index)"
            let publishedAt = Date(timeIntervalSince1970: 1_777_775_000 - Double(index))

            context.insert(
                SubscriptionRecord(
                    feedURL: feedURL,
                    title: title,
                    author: "UI Test Author \(index)",
                    artworkURL: artworkURL,
                    lastRefreshAt: refreshedAt
                )
            )
            let podcast = PodcastCacheRecord(
                feedURL: feedURL,
                title: title,
                author: "UI Test Author \(index)",
                summary: "A deterministic extra show seeded for UI performance tests.",
                websiteURL: "https://example.com/ui-test-extra-\(index)",
                artworkURL: artworkURL,
                updatedAt: refreshedAt
            )
            let resolvedArtworkPreview = usesVariedArtworkPreviews
                ? seededArtworkPreview(artworkURL: artworkURL, variantIndex: index)
                : artworkPreview
            if let resolvedArtworkPreview {
                podcast.storeArtworkPreviewIfChanged(resolvedArtworkPreview)
            }
            context.insert(podcast)

            let episode = EpisodeCacheRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                podcastTitle: title,
                title: "Extra Deterministic Episode \(index)",
                summary: "An extra deterministic episode seeded for UI performance tests.",
                showNotesHTML: "<p>Extra deterministic show notes.</p>",
                publishedAt: publishedAt,
                duration: 180,
                audioURL: audioURL,
                artworkURL: artworkURL,
                guid: episodeID,
                cachedAt: refreshedAt
            )
            if let resolvedArtworkPreview {
                episode.storeArtworkPreviewIfChanged(resolvedArtworkPreview)
            }
            context.insert(episode)
        }
    }

    private static func longShowNotesHTML() -> String {
        let paragraphCount = Int(ProcessInfo.processInfo.environment["OPENCAST_SEED_LONG_SHOW_NOTES_PARAGRAPHS"] ?? "") ?? 8_000
        var html = ""
        html.reserveCapacity(paragraphCount * 112)
        for index in 0..<paragraphCount {
            html += "<p>Long seeded show note paragraph \(index) with links, credits, chapters, and sponsor copy for cold-start playback measurement.</p>"
        }
        return html
    }

    static func seedOnboardingCompleted(in container: ModelContainer) throws {
        let context = ModelContext(container)
        try LocalPreferenceRecord.upsert(
            key: OnboardingStateStore.completedPreferenceKey,
            value: "true",
            modelContext: context
        )
        try context.save()
    }

    static func seedNotificationPromoBannerResolved(in container: ModelContainer) throws {
        let context = ModelContext(container)
        try LocalPreferenceRecord.upsert(
            key: NotificationPromoBannerStore.resolvedPreferenceKey,
            value: "true",
            modelContext: context
        )
        try context.save()
    }

    private static func deterministicArtworkURL() throws -> URL? {
        switch ProcessInfo.processInfo.environment["OPENCAST_UI_TEST_ARTWORK_VARIANT"]?.lowercased() {
        case "placeholder", "none", "missing":
            nil
        case "color-checker":
            try writeColorCheckerArtwork()
        default:
            try writeDeterministicArtwork()
        }
    }

    private static func seededArtworkPreview(artworkURL: String?, variantIndex: Int?) -> ArtworkPreview? {
        guard ProcessInfo.processInfo.environment["OPENCAST_SEED_ARTWORK_PREVIEW"] == "1" else {
            return nil
        }

        let variantIndex = variantIndex ?? 0
        let canonicalKey = ArtworkPreview.canonicalArtworkURLKey(for: artworkURL)
            ?? "opencast-ui-test-preview-\(variantIndex)"
        var rgbData = Data()
        rgbData.reserveCapacity(ArtworkPreview.requiredRGBByteCount(
            width: ArtworkPreview.fixedPixelWidth,
            height: ArtworkPreview.fixedPixelHeight
        ))
        for index in 0..<(ArtworkPreview.fixedPixelWidth * ArtworkPreview.fixedPixelHeight) {
            let row = index / ArtworkPreview.fixedPixelWidth
            let column = index % ArtworkPreview.fixedPixelWidth
            let red = 220 + (variantIndex + column * 3) % 33
            let green = 36 + (variantIndex * 17 + row * 11 + column * 5) % 128
            let blue = 28 + (variantIndex * 13 + row * 7 + column * 3) % 88
            rgbData.append(UInt8(red))
            rgbData.append(UInt8(green))
            rgbData.append(UInt8(blue))
        }

        return ArtworkPreview(
            version: ArtworkPreview.currentVersion,
            canonicalArtworkURLKey: canonicalKey,
            sourceHash: "opencast-ui-test-preview-v\(ArtworkPreview.currentVersion)-\(variantIndex)",
            pixelWidth: ArtworkPreview.fixedPixelWidth,
            pixelHeight: ArtworkPreview.fixedPixelHeight,
            rgbData: rgbData
        )
    }

    private static func writeDeterministicArtwork() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "opencast-ui-test-artwork.png")
        guard let artworkData = Data(base64Encoded: artworkPNGBase64, options: .ignoreUnknownCharacters) else {
            throw SeedDataError.invalidArtworkData
        }

        try artworkData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func writeColorCheckerArtwork() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "opencast-ui-test-artwork-color-checker.png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        let data = renderer.pngData { context in
            UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))

            let patches: [UIColor] = [
                UIColor(red: 0.95, green: 0.04, blue: 0.06, alpha: 1),
                UIColor(red: 0.02, green: 0.64, blue: 0.20, alpha: 1),
                UIColor(red: 0.05, green: 0.18, blue: 0.92, alpha: 1),
                UIColor(red: 1.00, green: 0.86, blue: 0.02, alpha: 1),
                UIColor(red: 0.98, green: 0.22, blue: 0.78, alpha: 1),
                UIColor(red: 0.00, green: 0.82, blue: 0.92, alpha: 1),
                UIColor(white: 0.98, alpha: 1),
                UIColor(white: 0.08, alpha: 1),
                UIColor(red: 1.00, green: 0.48, blue: 0.10, alpha: 1),
                UIColor(red: 0.45, green: 0.20, blue: 0.88, alpha: 1),
                UIColor(white: 0.50, alpha: 1),
                UIColor(red: 0.14, green: 0.58, blue: 0.78, alpha: 1),
                UIColor(red: 0.76, green: 0.08, blue: 0.20, alpha: 1),
                UIColor(red: 0.20, green: 0.75, blue: 0.48, alpha: 1),
                UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1),
                UIColor(red: 0.88, green: 0.84, blue: 0.72, alpha: 1)
            ]

            for row in 0..<4 {
                for column in 0..<4 {
                    patches[row * 4 + column].setFill()
                    context.fill(CGRect(x: column * 64 + 4, y: row * 64 + 4, width: 56, height: 56))
                }
            }

            UIColor(white: 1, alpha: 1).setStroke()
            context.cgContext.setLineWidth(3)
            context.cgContext.stroke(CGRect(x: 1.5, y: 1.5, width: 253, height: 253))
            UIColor(white: 0, alpha: 0.65).setStroke()
            context.cgContext.setLineWidth(2)
            context.cgContext.move(to: CGPoint(x: 0, y: 224))
            context.cgContext.addLine(to: CGPoint(x: 256, y: 224))
            context.cgContext.strokePath()
        }

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func writeDeterministicAudio() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "opencast-ui-test-episode.wav")
        let sampleRate: UInt32 = 8_000
        let durationSeconds = 300
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = Int(sampleRate) * durationSeconds
        let bytesPerSample = UInt16(MemoryLayout<Int16>.size)
        let blockAlign = channelCount * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)
        let audioByteCount = UInt32(sampleCount) * UInt32(blockAlign)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(36 + audioByteCount, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(bitsPerSample, to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(audioByteCount, to: &data)

        for sampleIndex in 0..<sampleCount {
            let phase = Double(sampleIndex) / Double(sampleRate)
            let sample = Int16((sin(phase * 440 * 2 * .pi) * 0.2) * Double(Int16.max))
            appendLittleEndian(sample, to: &data)
        }

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static let artworkPNGBase64 = """
    iVBORw0KGgoAAAANSUhEUgAAAMAAAABgCAYAAABLwH3pAAACPUlEQVR42u3cy1EWURCGYeIhDsEb/NwMxTAQwRsqKIgRTALGNTvsVTMsrNnhqe7nq3oj6PNsz9b26e29Hvqz9/Zx+yttVjpY6XClo5WOVzpZ6c2/m6dn5dvy6AEAQAAAIAA6AngXh1cGAAAAAAAAAADM0075AACgOYCzOLwyAAAAAAAAAAAAAAAAKA/gfRxeGQBLALvlAwAAAAQAAAKgJYDzOLwyAAAAAAAAAABgnp6XDwAAmgO4iMMrAwAAAAAAAAAAAAAAgPIAPsThlQGwBPCifAAAAIAAAEAAtATwMQ6vDAAAAAAAAAAAmKeX5QMAgOYAPsXhlQEAAAAAAAAAAAAAAEB5AJ/j8MoAWAJ4Vb6hAFifAQAAAAAAAMD/BvAlHt8gGQAAGAAAWH0Ar4cIAGsO4DIe3yAZAAAYAAAYAAAYAE8A4Gs8vkGyTgD2hggAAwAAAwAAawngWzy+QTIAADAAALD6APaHCABrDuB7PL5BMgAAMAAAMAAAMACeAMBVPL5Bsk4ANkM0FIAR8jHW8mOsTfkAAAAAAdAXwHUcXhkAAAAAAAAAADBPB+UDAIDmAH7E4ZUBAAAAAAAAAAAAAABAeQA/4/DKAFgCOCwfAAAAIAAAEAAtAdzE4ZUBAAAAAAAAAADzdFQ+AABoDuA2Dq8MAAAAAAAAAAAAAAAAygP4FYdXBsASwHH5AAAAAAEAgABoCeAuDq8MAAAAAAAAAACYp5PyAQBAcwC/4/DKAAAAAAAAAAAAAAAAoHh/AZXVKNQ/LY5mAAAAAElFTkSuQmCC
    """

    private enum SeedDataError: Error {
        case invalidArtworkData
    }
}
