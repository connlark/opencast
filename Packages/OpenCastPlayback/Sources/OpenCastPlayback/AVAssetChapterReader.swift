import AVFoundation
import Foundation
import OpenCastCore

public enum AVAssetChapterReader {
    public static func chapters(in asset: AVAsset) async throws -> [EpisodeChapter] {
        nonisolated(unsafe) let asset = asset
        let locales = try await asset.load(.availableChapterLocales)
        guard let locale = preferredLocale(among: locales) else {
            return []
        }

        let groups = try await asset.loadChapterMetadataGroups(
            withTitleLocale: locale,
            containingItemsWithCommonKeys: [.commonKeyTitle]
        )

        var chapters: [EpisodeChapter] = []
        for group in groups {
            let start = group.timeRange.start
            guard start.isNumeric else {
                continue
            }
            let end = CMTimeRangeGetEnd(group.timeRange)
            let title = await title(of: group)
            chapters.append(EpisodeChapter(
                id: chapters.count,
                title: title ?? "Chapter \(chapters.count + 1)",
                startTime: start.seconds,
                endTime: end.isNumeric && end.seconds > start.seconds ? end.seconds : nil
            ))
        }
        return chapters.sorted { $0.startTime < $1.startTime }
    }

    private static func preferredLocale(among locales: [Locale]) -> Locale? {
        guard !locales.isEmpty else {
            return nil
        }
        let preferredLanguageCodes = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode }
        for code in preferredLanguageCodes {
            if let match = locales.first(where: { $0.language.languageCode == code }) {
                return match
            }
        }
        return locales.first
    }

    private static func title(of group: AVTimedMetadataGroup) async -> String? {
        for item in group.items where item.commonKey == .commonKeyTitle {
            if let value = try? await item.load(.stringValue) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
