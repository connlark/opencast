import Foundation

nonisolated struct ResumeWidgetSnapshot: Codable, Equatable, Sendable {
    static let appGroup = "group.com.connor.opencast"
    static let kind = "OpenCastResume"
    static let filename = "resume-widget.json"
    static let maximumBytes = 256 * 1024
    static let staleInterval: TimeInterval = 24 * 60 * 60

    var version = 1
    let episodeID: String
    let title: String
    let showTitle: String
    let updatedAt: Date
    let progressBucket: Int
    let artwork: Data?

    var resumeURL: URL? {
        var components = URLComponents()
        components.scheme = "opencast"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "episode", value: episodeID)]
        return components.url
    }

    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(updatedAt) > Self.staleInterval || updatedAt.timeIntervalSince(date) > 300
    }

    func validate() throws {
        guard version == 1, !episodeID.isEmpty, episodeID.count <= 512, !title.isEmpty,
              title.count <= 512, showTitle.count <= 512, progressBucket >= 0,
              (artwork?.count ?? 0) <= 128 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
    }

    static func read(from directory: URL?) throws -> Self? {
        guard let directory else { return nil }
        let url = directory.appending(path: filename)
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            try value.validate()
            return value
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }
}
