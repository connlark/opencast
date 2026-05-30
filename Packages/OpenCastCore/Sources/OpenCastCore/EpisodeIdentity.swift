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
        let canonicalFeedURL = URLCanonicalizer.canonicalString(for: feedURL)
        let identityMaterial: String

        if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            identityMaterial = "guid:\(guid)"
        } else if let audioURL {
            identityMaterial = "audio:\(URLCanonicalizer.canonicalString(for: audioURL))"
        } else {
            let timestamp = publishedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown-date"
            identityMaterial = "title-date:\(title.normalizedForEpisodeIdentity)|\(timestamp)"
        }

        return EpisodeID(rawValue: sha256("\(canonicalFeedURL)|\(identityMaterial)"))
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
