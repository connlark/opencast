import CryptoKit
import Foundation

public enum EpisodeIdentity {
    public static func makeID(
        feedURL: URL,
        guid: String?,
        audioURL: URL?,
        title: String,
        publishedAt: Date?
    ) -> EpisodeID {
        makeID(
            canonicalFeedURL: URLCanonicalizer.canonicalString(for: feedURL),
            guid: guid,
            audioURL: audioURL,
            title: title,
            publishedAt: publishedAt
        )
    }

    static func makeID(
        canonicalFeedURL: String,
        guid: String?,
        audioURL: URL?,
        title: String,
        publishedAt: Date?
    ) -> EpisodeID {
        let identityMaterial: String

        if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            identityMaterial = "guid:\(guid)"
        } else if let audioURL {
            identityMaterial = "audio:\(URLCanonicalizer.canonicalString(for: audioURL))"
        } else {
            let timestamp = publishedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown-date"
            identityMaterial = "title-date:\(normalizedTitle(title))|\(timestamp)"
        }

        return EpisodeID(rawValue: sha256("\(canonicalFeedURL)|\(identityMaterial)"))
    }

    /// The whitespace/case normalization the title-date identity tier hashes.
    /// Exposed so identity reconciliation matches titles by the same rules.
    public static func normalizedTitle(_ title: String) -> String {
        title.normalizedForEpisodeIdentity
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }
}

private extension String {
    var normalizedForEpisodeIdentity: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
