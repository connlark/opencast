/// Providers that can contribute a directory result. Apple is the
/// ranking and display-metadata authority; Podcast Index supplements
/// (fallback, feed resolution, fill-in, gap-fill) only.
public enum PodcastDirectorySource: String, CaseIterable, Codable, Hashable, Sendable {
    case apple
    case podcastIndex
}
