import Foundation

public enum PublisherChaptersDocumentDecoder {
    public static let maximumChapterCount = 1_000
    public static let maximumTitleLength = 200
    /// About 31 years: far past any episode, and far below where the `Duration`
    /// and `CMTime` conversions of a timestamp stop being exact (or trap).
    public static let maximumTimestamp: TimeInterval = 1_000_000_000

    /// Podcasting 2.0 JSON chapters (jsonChapters 1.2) → display chapters, sorted by start, ids positional.
    ///
    /// Strict on the root, lenient inside it: entries without a usable start or title, entries
    /// starting past `maximumTimestamp`, and entries marked `toc: false` are dropped rather than
    /// failing the document. An end past `maximumTimestamp` reads as absent.
    public static func decode(_ data: Data) throws -> [EpisodeChapter] {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw PublisherChaptersDocumentError.invalidJSON
        }
        guard let entries = document.chapters else {
            throw PublisherChaptersDocumentError.malformedRoot
        }

        let candidates = entries.enumerated()
            .compactMap { offset, entry in entry.chapter.map { (offset: offset, chapter: $0) } }
            .sorted { ($0.chapter.startTime, $0.offset) < ($1.chapter.startTime, $1.offset) }
            .map(\.chapter)

        var chapters: [EpisodeChapter] = []
        for candidate in candidates {
            guard chapters.count < maximumChapterCount else { break }
            if chapters.last?.startTime == candidate.startTime { continue }
            chapters.append(EpisodeChapter(
                id: chapters.count,
                title: candidate.title,
                startTime: candidate.startTime,
                endTime: candidate.endTime
            ))
        }
        return chapters
    }

    private struct Document: Decodable {
        let chapters: [Entry]?

        init(from decoder: any Decoder) {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            chapters = try? container?.decode([Entry].self, forKey: .chapters)
        }

        private enum CodingKeys: String, CodingKey {
            case chapters
        }
    }

    private struct Entry: Decodable {
        let chapter: EpisodeChapter?

        init(from decoder: any Decoder) {
            chapter = Self.chapter(in: try? decoder.container(keyedBy: CodingKeys.self))
        }

        private static func chapter(in container: KeyedDecodingContainer<CodingKeys>?) -> EpisodeChapter? {
            guard let container,
                  (try? container.decode(Bool.self, forKey: .toc)) != false,
                  let startTime = try? container.decode(Double.self, forKey: .startTime),
                  (0...PublisherChaptersDocumentDecoder.maximumTimestamp).contains(startTime),
                  let title = try? container.decode(String.self, forKey: .title)
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else {
                return nil
            }
            let endTime = (try? container.decode(Double.self, forKey: .endTime))
                .flatMap { $0 > startTime && $0 <= PublisherChaptersDocumentDecoder.maximumTimestamp ? $0 : nil }
            return EpisodeChapter(
                id: 0,
                title: String(title.prefix(PublisherChaptersDocumentDecoder.maximumTitleLength)),
                startTime: startTime,
                endTime: endTime
            )
        }

        private enum CodingKeys: String, CodingKey {
            case startTime
            case endTime
            case title
            case toc
        }
    }
}
